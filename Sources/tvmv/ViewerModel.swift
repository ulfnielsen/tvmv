import SwiftUI

/// Owns one document window's render lifecycle: initial render after the page is
/// ready, live reload with scroll preservation, outline, find, and print.
@MainActor
final class ViewerModel: ObservableObject {
    @Published var outline: [OutlineItem] = []
    @Published var errorMessage: String?
    @Published var findCount = 0
    @Published var findIndex = 0   // 1-based; 0 when no matches

    let fileURL: URL?
    private var text: String

    private var controller: MarkdownWebController?
    private var watcher: FileWatcher?
    private var isReady = false

    init(text: String, fileURL: URL?) {
        self.text = text
        self.fileURL = fileURL
    }

    func attach(controller: MarkdownWebController) {
        self.controller = controller
    }

    /// Called from MarkdownWebView's `onReady` (web view didFinish) — boot.js is live.
    func pageReady() {
        isReady = true
        Task { await renderCurrent() }
    }

    private func renderCurrent() async {
        guard isReady, let controller else { return }
        let html = renderHTML(text)
        let base = "\(AssetSchemeHandler.scheme)://doc/"
        await controller.setContent(bodyHTML: html, docBaseHref: base)
        await controller.applyStyle(json: AppSettings.shared.styleJSON)
    }

    func applyStyle() async {
        guard isReady else { return }
        await controller?.applyStyle(json: AppSettings.shared.styleJSON)
    }

    func startWatching() {
        guard let url = fileURL else { return }
        watcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in await self?.reload() }
        }
        watcher?.start()
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Re-read the file from disk and re-render, preserving scroll position.
    func reload() async {
        guard isReady, let url = fileURL, let controller,
              let data = try? Data(contentsOf: url) else { return }
        let ratio = await controller.getScrollRatio()
        text = MarkdownText.decode(data).text
        await renderCurrent()
        try? await Task.sleep(nanoseconds: 60_000_000) // let layout settle
        await controller.setScrollRatio(ratio)
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

    func printDoc() { controller?.printDocument() }
}
