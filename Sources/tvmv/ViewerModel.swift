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

    let fileURL: URL?
    private var text: String

    private var controller: MarkdownWebController?
    private var watcher: FileWatcher?
    private var cssWatcher: FileWatcher?
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
        await controller.setUserCSS(UserCSS.load() ?? "")
        await updateChrome()
    }

    func applyUserCSS() async {
        guard isReady else { return }
        await controller?.setUserCSS(UserCSS.load() ?? "")
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
    }

    func startWatching() {
        if let url = fileURL {
            watcher = FileWatcher(url: url) { [weak self] in
                Task { @MainActor in await self?.reload() }
            }
            watcher?.start()
        }
        // Live-reload the user CSS override while it's being edited.
        if FileManager.default.fileExists(atPath: UserCSS.url.path) {
            cssWatcher = FileWatcher(url: UserCSS.url) { [weak self] in
                Task { @MainActor in await self?.applyUserCSS() }
            }
            cssWatcher?.start()
        }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        cssWatcher?.stop()
        cssWatcher = nil
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
