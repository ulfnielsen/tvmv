import TVMVCore
import SwiftUI
import AppKit

struct ViewerWindow: View {
    // The document is consumed in init (seeds the model); storing it here would
    // keep a second copy of the full text alive for the window's lifetime.
    let fileURL: URL?

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model: ViewerModel

    @State private var columns: NavigationSplitViewVisibility = .automatic
    @State private var selection: OutlineItem.ID?
    @State private var showFind = false
    @State private var findText = ""
    @FocusState private var findFocused: Bool

    init(document: MarkdownDocument, fileURL: URL?) {
        self.fileURL = fileURL
        _model = StateObject(wrappedValue: ViewerModel(
            text: document.text, fileURL: fileURL,
            encoding: document.encodingUsed, lineEnding: document.lineEndingUsed))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(model.outline, selection: $selection) { item in
                Text(item.title)
                    .padding(.leading, CGFloat((item.level - 1) * 12))
                    .lineLimit(1)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 240)
            .scrollContentBackground(model.chromeColor == nil ? .automatic : .hidden)
            .background(model.chromeColor.map { Color(nsColor: $0) } ?? .clear)
        } detail: {
            HSplitView {
                if model.isEditing {
                    editorPane
                        .frame(minWidth: 280,
                               idealWidth: settings.editorPaneWidth > 0
                                   ? CGFloat(settings.editorPaneWidth) : nil)
                        .background(GeometryReader { geo in
                            Color.clear.onChange(of: geo.size.width) { _, w in
                                settings.editorPaneWidth = Double(w)
                            }
                        })
                }
                webView
                    .frame(minWidth: 320)
                    .overlay(alignment: .top) {
                        if model.externalChangePending { externalChangeBanner }
                    }
                    .overlay(alignment: .topTrailing) { if showFind { findBar } }
                    .overlay(alignment: .bottom) {
                        if model.errorMessage != nil { errorBanner }
                    }
            }
        }
        .background { WindowChrome(color: model.chromeColor) }
        .background { WindowCloseGuard(
            needsFlow: { model.isDirty || model.isEditing },
            flush: { await model.flushEditorText() },
            isDirty: { model.isDirty },
            save: { model.save(); return !model.isDirty }
        ) }
        .navigationTitle(fileURL?.lastPathComponent ?? "Untitled")
        // Dirty indicator. Deliberately NOT window.isDocumentEdited: marking a
        // DocumentGroup(viewing:) window "edited" drags in AppKit's autosave
        // machinery, which can't save this document and alerts about it.
        .navigationSubtitle(model.isDirty ? "Edited" : "")
        .onChange(of: selection) { _, new in
            if let new, let item = model.outline.first(where: { $0.id == new }) {
                model.scrollTo(item)
            }
        }
        // Live-apply typography/theme: styleJSON changes whenever any setting does.
        .onChange(of: settings.styleJSON) { Task { await model.applyStyle() } }
        // Editor-only settings (font, size) aren't part of styleJSON; watch
        // the editor payload so any of them live-applies too.
        .onChange(of: settings.editorStyleJSON) { Task { await model.applyStyle() } }
        // Re-apply when the custom-CSS file is changed in Settings.
        .onChange(of: settings.customCSSPath) { model.cssPathChanged() }
        // Re-resolve auto theme when the system appearance flips.
        .onChange(of: colorScheme) {
            if settings.theme == .auto { Task { await model.applyStyle() } }
        }
        .onAppear {
            columns = settings.showOutline ? .all : .detailOnly
            model.startWatching()
        }
        .onDisappear { model.stopWatching() }
        .alert("Save Failed", isPresented: Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.saveError ?? "")
        }
        // Publish this window's command actions to the menu only while it is the
        // focused scene — so Find/Print/Reload/Toggle-Outline hit just this window.
        .focusedSceneValue(\.viewerCommands, ViewerCommands(
            find: {
                showFind = true
                // Defer focus until the bar is in the hierarchy this runloop turn.
                DispatchQueue.main.async { findFocused = true }
            },
            printDocument: { model.printDoc() },
            reload: { Task { await model.reload() } },
            toggleOutline: { columns = (columns == .detailOnly) ? .all : .detailOnly },
            toggleEditing: { model.toggleEditing() },
            save: { Task { await model.flushAndSave() } },
            canSave: (model.isDirty || model.isEditing) && fileURL != nil,
            canEdit: fileURL != nil
        ))
    }

    private var webView: some View {
        MarkdownWebView(
            appWebDir: WebResources.baseURL,
            docDir: fileURL?.deletingLastPathComponent(),
            callbacks: MarkdownWebViewCallbacks(
                onOutline: { items in model.outline = items },
                onRenderComplete: { },
                // While editing, half-typed mermaid/math makes nearly every
                // debounced re-render reject transiently — suppress the banner
                // there (mermaid draws its own in-place error graphic anyway).
                onError: { msg in if !model.isEditing { model.errorMessage = msg } },
                onReady: { model.pageReady() },
                onSourceClick: { line in model.previewClicked(line: line) }
            ),
            onMakeController: { controller in model.attach(controller: controller) }
        )
    }

    private var editorPane: some View {
        CodeMirrorEditorPane(
            appWebDir: WebResources.baseURL,
            callbacks: EditorBridgeCallbacks(
                onReady: { model.editorReady(bridge: $0) },
                onTextChanged: { model.editorTextChanged($0) },
                onCursorMoved: { line, offset in model.editorCursorMoved(line: line, offset: offset) },
                onScrolled: { line in model.editorScrolled(topLine: line) },
                onError: { msg in model.errorMessage = msg }
            ),
            onMakeBridge: { model.attach(editor: $0) }
        )
    }

    private var errorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            Text(model.errorMessage ?? "")
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .padding(8)
    }

    private var externalChangeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("File changed on disk")
                .font(.caption)
            Spacer()
            Button("Reload (discards edits)") {
                Task { await model.discardAndReload() }
            }
            .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .padding(8)
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $findText)
                .textFieldStyle(.plain)
                .frame(width: 200)
                .focused($findFocused)
                .onSubmit { model.findNext(forward: true) }
                .onChange(of: findText) { model.find(findText) }
            Text(matchLabel)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Divider().frame(height: 16)
            Button { model.findNext(forward: false) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(model.findCount == 0)
            Button { model.findNext(forward: true) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(model.findCount == 0)
            Button { closeFind() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .padding(8)
        .onExitCommand { closeFind() }
    }

    private var matchLabel: String {
        if findText.isEmpty { return "" }
        return model.findCount == 0 ? "Not found" : "\(model.findIndex)/\(model.findCount)"
    }

    private func closeFind() {
        showFind = false
        findText = ""
        model.clearFind()
    }
}

/// Paints the host NSWindow's background so the theme color extends past the
/// content into the window chrome — including the title bar (made transparent so
/// it shows the window background) and the area behind the sidebar. Chrome text
/// (title, sidebar, traffic lights) is flipped light/dark for legibility.
private struct WindowChrome: NSViewRepresentable {
    var color: NSColor?
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        let color = color
        DispatchQueue.main.async {
            guard let w = nsView.window else { return }
            if let c = color {
                w.titlebarAppearsTransparent = true   // show the window bg in the title bar
                w.backgroundColor = c
                let lum: CGFloat = c.usingColorSpace(.sRGB).map {
                    0.299 * $0.redComponent + 0.587 * $0.greenComponent + 0.114 * $0.blueComponent
                } ?? 1
                w.appearance = NSAppearance(named: lum < 0.6 ? .darkAqua : .aqua)
            } else {
                w.titlebarAppearsTransparent = false
                w.backgroundColor = .windowBackgroundColor
                w.appearance = nil
            }
        }
    }
}
