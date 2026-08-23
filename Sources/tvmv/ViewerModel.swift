import TVMVCore
import SwiftUI
import AppKit

/// Owns one document window's render lifecycle: initial render after the page is
/// ready, live reload with scroll preservation, outline, find, and print.
@MainActor
final class ViewerModel: ObservableObject {
    @Published var outline: [OutlineItem] = []
    @Published var errorMessage: String?
    @Published var findCount = 0
    @Published var findIndex = 0   // 1-based; 0 when no matches
    @Published var chromeColor: NSColor?   // lightened page background, for window + sidebar

    // MARK: Editing state
    @Published var isEditing = false
    @Published private(set) var isDirty = false
    /// The file changed on disk while there are unsaved edits; the UI shows a
    /// banner and the user decides (reload discards, save overwrites).
    @Published var externalChangePending = false
    @Published var saveError: String?

    let fileURL: URL?
    let encodingUsed: TextEncodingUsed
    /// Newline style of the file on disk; `text` is always LF-normalized and
    /// saves restore this style.
    let lineEndingUsed: LineEndingUsed
    @Published private(set) var text: String

    private var lastSavedText: String
    private var controller: MarkdownWebController?
    private var editorBridge: EditorBridge?
    /// Latest cursor/scroll reported by the editor's events; makes position
    /// capture on ⌘E-off synchronous even though the editor is async.
    private var lastEditorPosition = EditorPosition(cursorOffset: 0, topLine: 1)
    /// Where the editor was when its pane last closed, for exact restore.
    private var savedEditorPosition: EditorPosition?
    /// Preview's top source line when the editor pane last closed; if the
    /// preview moved while the editor was hidden, re-entry re-anchors to the
    /// preview instead of restoring ("the pane you touched last wins").
    private var previewTopLineAtEditorClose: Int?
    /// In-flight capture of the preview's top line at editor close; awaited on
    /// reopen so a fast close-then-open toggle never reads a stale value.
    private var editorCloseSync: Task<Void, Never>?
    /// Guards toggleEditing()'s closing branch against re-entry while the
    /// deterministic flush is in flight (a double ⌘E-off before it settles).
    private var closingEditor = false
    private var renderDebounce: DispatchWorkItem?
    private var previewNeedsRender = false
    private var scrollSyncDebounce: DispatchWorkItem?
    private var cursorSyncDebounce: DispatchWorkItem?
    private var watcher: FileWatcher?
    private var cssWatcher: FileWatcher?
    private var isReady = false

    init(
        text: String,
        fileURL: URL?,
        encoding: TextEncodingUsed = .utf8,
        lineEnding: LineEndingUsed = .lf
    ) {
        self.text = text
        self.lastSavedText = text
        self.fileURL = fileURL
        self.encodingUsed = encoding
        self.lineEndingUsed = lineEnding
    }

    func attach(controller: MarkdownWebController) {
        self.controller = controller
    }

    // MARK: Editing

    func attach(editor: EditorBridge) {
        editorBridge = editor
        // Positioning waits for the page's `ready` event (editorReady()).
    }

    /// The editor page is live: seed it with the document, style, and the
    /// restore-vs-reanchor position, then hand it focus.
    func editorReady(bridge: EditorBridge) {
        Task { [weak self] in
            guard let self else { return }
            await self.editorCloseSync?.value
            guard bridge === self.editorBridge, let bridge = self.editorBridge else { return }
            await bridge.setText(self.text, resetHistory: true)
            await bridge.applyStyle(json: AppSettings.shared.editorStyleJSON)
            let previewLine = await self.controller?.topVisibleSourceLine()
            if let saved = self.savedEditorPosition,
               previewLine == self.previewTopLineAtEditorClose {
                await bridge.restore(saved)
                self.lastEditorPosition = saved
            } else {
                let line = previewLine ?? 1
                await bridge.scrollToLine(line, placeCursor: true)
                self.lastEditorPosition = EditorPosition(cursorOffset: 0, topLine: line)
            }
            bridge.focus()
        }
    }

    /// The editor pane is closing (⌘E off): remember where it was, and where
    /// the preview was, so re-entry can decide between restore and re-anchor.
    func editorClosed() {
        savedEditorPosition = lastEditorPosition
        editorBridge = nil
        renderDebounce?.cancel()
        editorCloseSync = Task { [weak self] in
            guard let self else { return }
            if self.previewNeedsRender {
                // Flush the last edit's render before recording the preview
                // position, preserving scroll so leaving edit mode never jumps.
                let ratio = await self.controller?.getScrollRatio() ?? 0
                await self.renderCurrent()
                try? await Task.sleep(nanoseconds: 60_000_000) // let layout settle
                await self.controller?.setScrollRatio(ratio)
                self.previewNeedsRender = false
            }
            self.previewTopLineAtEditorClose = await self.controller?.topVisibleSourceLine()
        }
        controller?.focus()
    }

    func toggleEditing() {
        if isEditing {
            guard !closingEditor else { return }
            closingEditor = true
            let bridge = editorBridge
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Deterministic flush: the page's blur-flush races webview
                // teardown, so pull the doc explicitly — ⌘E-off must never
                // drop keystrokes still inside the 100 ms debounce.
                if let bridge, let current = await bridge.getText() {
                    self.textEdited(current)
                }
                self.isEditing = false
                self.editorClosed()
                self.closingEditor = false
            }
        } else {
            saveError = nil
            isEditing = true
            // CodeMirrorEditorPane's makeNSView calls attach(editor:); the
            // page's `ready` event then calls editorReady(), which positions
            // and focuses. Nothing more to do here.
        }
    }

    /// Editor keystrokes: adopt the text, track dirtiness, and re-render the
    /// preview debounced, re-anchored to the editor's viewport afterward.
    func textEdited(_ newText: String) {
        guard newText != text else { return }
        text = newText
        isDirty = (newText != lastSavedText)
        previewNeedsRender = true
        renderDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in await self?.renderAfterEdit() }
        }
        renderDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func renderAfterEdit() async {
        previewNeedsRender = false
        await renderCurrent()
        try? await Task.sleep(nanoseconds: 60_000_000) // let layout settle
        if isEditing {
            await controller?.scrollToSourceLine(lastEditorPosition.topLine)
        }
    }

    /// Editor event: text changed (already debounced ~100 ms page-side).
    func editorTextChanged(_ newText: String) {
        textEdited(newText)
    }

    /// Editor event: scrolled. Keep the preview's top aligned (debounced).
    func editorScrolled(topLine: Int) {
        lastEditorPosition.topLine = topLine
        guard isEditing else { return }
        scrollSyncDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.controller?.scrollToSourceLine(topLine) }
        }
        scrollSyncDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Editor event: cursor moved. Reveal its block in the preview only if
    /// offscreen (debounced).
    func editorCursorMoved(line: Int, offset: Int) {
        lastEditorPosition.cursorOffset = offset
        guard isEditing else { return }
        cursorSyncDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.controller?.revealSourceLine(line) }
        }
        cursorSyncDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Preview click: jump the editor to the clicked block's source line and
    /// hand it focus. No-op while the editor pane is closed, so plain viewing
    /// keeps its normal click behavior (selection, links).
    func previewClicked(line: Int) {
        guard isEditing, let bridge = editorBridge else { return }
        Task {
            await bridge.scrollToLine(line, placeCursor: true)
            bridge.focus()
        }
    }

    // MARK: Save

    /// Write `text` back to the file in its original encoding. Synchronous so
    /// the window-close guard can save-and-close in one step.
    func save() {
        guard let url = fileURL, isDirty else { return }
        do {
            try MarkdownText.encode(text, encoding: encodingUsed, lineEnding: lineEndingUsed)
                .write(to: url, options: .atomic)
            lastSavedText = text
            isDirty = false
            externalChangePending = false   // we just overwrote the external change
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Pull the authoritative document from the editor into the model without
    /// saving (covers keystrokes inside the page's 100 ms debounce window).
    /// Falls back silently when the bridge is gone — the cached text is then
    /// at worst <100 ms stale, in a scenario where the editor process died.
    func flushEditorText() async {
        if let bridge = editorBridge, let current = await bridge.getText() {
            textEdited(current)
        }
    }

    /// Flush, then save. ⌘S and the close flow's Save button use this.
    func flushAndSave() async {
        await flushEditorText()
        save()
    }

    /// Called from MarkdownWebView's `onReady` (web view didFinish) — boot.js is live.
    func pageReady() {
        isReady = true
        Task { await renderCurrent() }
    }

    private func renderCurrent() async {
        guard isReady, let controller else { return }
        let html = renderHTML(text, sourcePos: true)
        let base = "\(AssetSchemeHandler.scheme)://doc/"
        await controller.setContent(bodyHTML: html, docBaseHref: base)
        await controller.applyStyle(json: AppSettings.shared.styleJSON)
        await controller.setUserCSS(UserCSS.load(AppSettings.shared.customCSSURL) ?? "")
        await updateChrome()
    }

    func applyUserCSS() async {
        guard isReady else { return }
        await controller?.setUserCSS(UserCSS.load(AppSettings.shared.customCSSURL) ?? "")
        await updateChrome()
    }

    /// Tint the window chrome (sidebar + window background) to a slightly
    /// lightened version of the page's background color, so the theme extends
    /// past the content into the app window.
    private func updateChrome() async {
        guard let controller, let css = await controller.pageBackgroundColor(),
              let base = Self.parseCSSColor(css), base.alphaComponent > 0.05 else { return }
        chromeColor = base.blended(withFraction: 0.16, of: .white) ?? base
    }

    /// Parse "rgb(r, g, b)" / "rgba(r, g, b, a)" into an NSColor.
    static func parseCSSColor(_ s: String) -> NSColor? {
        let nums = s.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .filter { !$0.isEmpty }.compactMap { Double($0) }
        guard nums.count >= 3 else { return nil }
        let alpha = nums.count >= 4 ? nums[3] : 1.0
        return NSColor(srgbRed: nums[0] / 255, green: nums[1] / 255, blue: nums[2] / 255, alpha: alpha)
    }

    func applyStyle() async {
        guard isReady else { return }
        await controller?.applyStyle(json: AppSettings.shared.styleJSON)
        await editorBridge?.applyStyle(json: AppSettings.shared.editorStyleJSON)
    }

    func startWatching() {
        if let url = fileURL {
            watcher = FileWatcher(url: url) { [weak self] in
                Task { @MainActor in await self?.reload() }
            }
            watcher?.start()
        }
        // Live-reload the user CSS override while it's being edited.
        startCSSWatcher()
    }

    private func startCSSWatcher() {
        cssWatcher?.stop()
        cssWatcher = nil
        guard let cssURL = AppSettings.shared.customCSSURL,
              FileManager.default.fileExists(atPath: cssURL.path) else { return }
        cssWatcher = FileWatcher(url: cssURL) { [weak self] in
            Task { @MainActor in await self?.applyUserCSS() }
        }
        cssWatcher?.start()
    }

    /// Re-watch + re-apply when the custom-CSS path changes in Settings.
    func cssPathChanged() {
        startCSSWatcher()
        Task { await applyUserCSS() }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        cssWatcher?.stop()
        cssWatcher = nil
    }

    /// Re-read the file from disk. Own-save echoes (disk == text) are ignored;
    /// external changes while dirty raise a banner instead of clobbering edits;
    /// otherwise adopt the new text and re-render, preserving scroll.
    func reload(force: Bool = false) async {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        // Adopt any keystrokes still inside the editor page's debounce window
        // before judging dirtiness, or an external change racing a fresh
        // keystroke would clobber it. Never on the force path: discard means
        // the editor's unsaved content is intentionally being dropped.
        if isEditing && !force {
            await flushEditorText()
        }
        let decoded = MarkdownText.decode(data).text
        if decoded == text && !force {
            // Buffer already matches disk. If we were dirty, the external
            // write caught up with our edits — nothing left unsaved, so any
            // pending-change banner would be lying too.
            if isDirty {
                lastSavedText = decoded
                isDirty = false
                externalChangePending = false
            }
            return
        }
        if isDirty {
            externalChangePending = true                    // user decides; never clobber
            return
        }
        text = decoded
        lastSavedText = decoded
        if isEditing, let bridge = editorBridge {
            // Programmatic replacement: fresh history so ⌘Z can't resurrect
            // the pre-reload text. The resulting textChanged echo is a no-op
            // (textEdited guards newText != text).
            await bridge.setText(decoded, resetHistory: true)
        }
        guard isReady, let controller else { return }
        let ratio = await controller.getScrollRatio()
        await renderCurrent()
        try? await Task.sleep(nanoseconds: 60_000_000) // let layout settle
        await controller.setScrollRatio(ratio)
    }

    /// Banner action: drop unsaved edits and adopt the on-disk content.
    func discardAndReload() async {
        renderDebounce?.cancel()
        previewNeedsRender = false   // the forced reload below renders anyway
        isDirty = false
        externalChangePending = false
        await reload(force: true)
    }

    func scrollTo(_ item: OutlineItem) {
        Task { await controller?.scrollToAnchor(item.anchor) }
    }

    func find(_ query: String) {
        Task {
            let r = await controller?.find(query)
            findCount = r?.count ?? 0
            findIndex = r?.index ?? 0
        }
    }

    func findNext(forward: Bool) {
        Task {
            let r = await controller?.findNext(forward: forward)
            findCount = r?.count ?? 0
            findIndex = r?.index ?? 0
        }
    }

    func clearFind() {
        findCount = 0
        findIndex = 0
        Task { await controller?.clearFind() }
    }

    func printDoc() {
        // Use the file's base name (no extension) so the print job and the
        // Save-as-PDF default read as e.g. "ui-guide", not the app name.
        let title = fileURL?.deletingPathExtension().lastPathComponent
        controller?.printDocument(jobTitle: title)
    }
}
