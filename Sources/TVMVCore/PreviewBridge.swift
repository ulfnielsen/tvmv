import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#endif

/// A click on a rendered preview block, as reported by boot.js.
///
/// `line`/`endLine` are the block's 1-based source span (cmark sourcepos).
/// `word` and `ordinal` describe the word under the pointer — which occurrence
/// of it the click landed on within that block — and are absent when the click
/// was not on text. See `SourceClickResolver`.
public struct SourceClick: Equatable, Sendable {
    public var line: Int
    public var endLine: Int
    public var word: String?
    public var ordinal: Int

    public init(line: Int, endLine: Int, word: String? = nil, ordinal: Int = 1) {
        self.line = line
        self.endLine = endLine
        self.word = word
        self.ordinal = ordinal
    }
}

/// Delivers messages from the JS side back to SwiftUI.
/// A delegate closure is sufficient for our needs.
public struct MarkdownWebViewCallbacks {
    public var onOutline: (@MainActor ([OutlineItem]) -> Void)?
    public var onRenderComplete: (@MainActor () -> Void)?
    public var onError: (@MainActor (String) -> Void)?
    /// Fired when the template page finishes loading (boot.js is live and the
    /// `window.tvmv` API is callable). The owner renders content on this signal.
    public var onReady: (@MainActor () -> Void)?
    /// Fired when the user clicks a rendered block; carries the block's source
    /// line span and the clicked word, for preview→editor jumps.
    public var onSourceClick: (@MainActor (SourceClick) -> Void)?

    public init(
        onOutline: (@MainActor ([OutlineItem]) -> Void)? = nil,
        onRenderComplete: (@MainActor () -> Void)? = nil,
        onError: (@MainActor (String) -> Void)? = nil,
        onReady: (@MainActor () -> Void)? = nil,
        onSourceClick: (@MainActor (SourceClick) -> Void)? = nil
    ) {
        self.onOutline = onOutline
        self.onRenderComplete = onRenderComplete
        self.onError = onError
        self.onReady = onReady
        self.onSourceClick = onSourceClick
    }
}

/// Shared (Mac + iOS) coordinator for the preview web view: builds the
/// configuration (asset scheme + message channel), receives boot.js messages,
/// and hands the platform wrapper a MarkdownWebController once attached.
@MainActor
public final class PreviewCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    public var callbacks: MarkdownWebViewCallbacks
    /// External links (http/https/mailto) are handed here; nil cancels them.
    /// Mac injects NSWorkspace.open, iOS injects UIApplication.open.
    public var openExternalURL: (@MainActor (URL) -> Void)?

    weak var webView: WKWebView?
    var schemeHandler: AssetSchemeHandler?
    var controller: MarkdownWebController?

    public init(callbacks: MarkdownWebViewCallbacks) {
        self.callbacks = callbacks
    }

    /// Build the configuration the host web view must be created with.
    public func makeConfiguration(appWebDir: URL, docDir: URL?) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        let handler = AssetSchemeHandler(appBaseDir: appWebDir, docBaseDir: docDir)
        schemeHandler = handler
        configuration.setURLSchemeHandler(handler, forURLScheme: AssetSchemeHandler.scheme)
        configuration.userContentController.add(self, name: "tvmv")
        return configuration
    }

    /// Wire a platform-created web view and start loading the template page.
    public func attach(_ webView: WKWebView) -> MarkdownWebController {
        webView.navigationDelegate = self
        self.webView = webView
        let controller = MarkdownWebController(coordinator: self)
        self.controller = controller
        if let templateURL = URL(string: "\(AssetSchemeHandler.scheme)://app/template.html") {
            webView.load(URLRequest(url: templateURL))
        }
        return controller
    }

    /// Keep the scheme handler's document directory in sync.
    public func setDocumentDirectory(_ url: URL?) {
        schemeHandler?.setDocumentDirectory(url)
    }

    // MARK: WKScriptMessageHandler

    public nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            guard message.name == "tvmv",
                  let dict = message.body as? [String: Any],
                  let type = dict["type"] as? String
            else { return }

            switch type {
            case "outline":
                let raw = dict["items"] as? [[String: Any]] ?? []
                let items: [OutlineItem] = raw.compactMap { entry in
                    guard let level = entry["level"] as? Int,
                          let title = entry["title"] as? String,
                          let anchor = entry["anchor"] as? String
                    else { return nil }
                    return OutlineItem(level: level, title: title, anchor: anchor)
                }
                callbacks.onOutline?(items)

            case "renderComplete":
                callbacks.onRenderComplete?()

            case "sourceClick":
                if let line = dict["line"] as? Int {
                    callbacks.onSourceClick?(SourceClick(
                        line: line,
                        endLine: dict["endLine"] as? Int ?? line,
                        word: dict["word"] as? String,
                        ordinal: dict["ordinal"] as? Int ?? 1
                    ))
                }

            case "error":
                let msg = dict["message"] as? String ?? "Unknown error"
                callbacks.onError?(msg)

            default:
                break
            }
        }
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The template page (and boot.js) has loaded; `window.tvmv` is callable.
        callbacks.onReady?()
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let scheme = url.scheme?.lowercased()

        // Allow our own asset scheme.
        if scheme == AssetSchemeHandler.scheme {
            decisionHandler(.allow)
            return
        }

        // Allow same-page fragment navigation (#anchor).
        if url.fragment != nil,
           let current = webView.url,
           url.scheme == current.scheme,
           url.host == current.host,
           url.path == current.path {
            decisionHandler(.allow)
            return
        }

        // External links: hand to the host platform (browser/mail).
        if scheme == "http" || scheme == "https" || scheme == "mailto" {
            openExternalURL?(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.cancel)
    }
}

/// Imperative command surface the app calls. All work hops to the main actor
/// because WKWebView and the bridge are main-actor isolated.
@MainActor
public final class MarkdownWebController {
    private weak var coordinator: PreviewCoordinator?

    init(coordinator: PreviewCoordinator) {
        self.coordinator = coordinator
    }

    private var webView: WKWebView? { coordinator?.webView }

    // MARK: Content

    public func setContent(bodyHTML: String, docBaseHref: String) async {
        // Argument-based call: WebKit serializes the HTML natively instead of
        // us JSON-encoding a second document-sized JavaScript source string.
        guard let webView else { return }
        _ = try? await webView.callAsyncJavaScript(
            "window.tvmv.render(bodyHTML, docBaseHref);",
            arguments: ["bodyHTML": bodyHTML, "docBaseHref": docBaseHref],
            in: nil, contentWorld: .page)
    }

    /// Resolves after the page has completed a layout+paint pass (double
    /// requestAnimationFrame). Replaces guessed fixed sleeps before scroll
    /// restoration: correct on slow layouts, immediate on fast ones.
    public func waitForLayoutSettle() async {
        guard let webView else { return }
        _ = try? await webView.callAsyncJavaScript(
            """
            await new Promise(function (resolve) {
                requestAnimationFrame(function () {
                    requestAnimationFrame(function () { resolve(); });
                });
            });
            """,
            arguments: [:], in: nil, contentWorld: .page)
    }

    public func applyStyle(json: String) async {
        let js = "window.tvmv.applyStyle(\(JSString.literal(json)));"
        await run(js)
    }

    /// Inject the user's custom stylesheet (overrides the theme). Empty clears it.
    public func setUserCSS(_ css: String) async {
        let js = "window.tvmv.applyUserCSS(\(JSString.literal(css)));"
        await run(js)
    }

    /// The page's effective background color (e.g. "rgb(0, 133, 124)"), so the
    /// app can tint its window chrome to match the theme.
    public func pageBackgroundColor() async -> String? {
        await evaluate("getComputedStyle(document.body).backgroundColor") as? String
    }

    public func scrollToAnchor(_ anchor: String) async {
        let js = "window.tvmv.scrollToAnchor(\(JSString.literal(anchor)));"
        await run(js)
    }

    /// Rendered-page PDF for share/export flows.
    public func pdfData() async -> Data? {
        guard let webView else { return nil }
        return try? await webView.pdf(configuration: .init())
    }

    // MARK: Find (JS-backed via window.tvmv: returns total count + 1-based index)

    public struct FindResult: Sendable, Equatable {
        public var count: Int
        public var index: Int
    }

    @discardableResult
    public func find(_ string: String) async -> FindResult {
        await findCall("window.tvmv.find(\(JSString.literal(string)))")
    }

    @discardableResult
    public func findNext(forward: Bool) async -> FindResult {
        await findCall("window.tvmv.findNext(\(forward ? 1 : -1))")
    }

    public func clearFind() async {
        await run("window.tvmv && window.tvmv.clearFind && window.tvmv.clearFind();")
    }

    private func findCall(_ expr: String) async -> FindResult {
        // Round-trip through JSON so the {count,index} object decodes reliably.
        let js = "JSON.stringify(\(expr))"
        guard let string = await evaluate(js) as? String,
              let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return FindResult(count: 0, index: 0) }
        let count = (obj["count"] as? NSNumber)?.intValue ?? 0
        let index = (obj["index"] as? NSNumber)?.intValue ?? 0
        return FindResult(count: count, index: index)
    }

#if os(macOS)
    // MARK: Print (surfaces Save-as-PDF)

    public func printDocument(jobTitle: String? = nil) {
        guard let webView else { return }
        let printInfo = NSPrintInfo.shared
        let operation = webView.printOperation(with: printInfo)
        operation.view?.frame = webView.bounds
        // Carry the document's name into the print job so the print queue and the
        // "Save as PDF" default filename read as the file, not "tvmv". Without
        // this the job title falls back to the web view's (empty) page title and
        // then the app name.
        if let jobTitle, !jobTitle.isEmpty {
            operation.jobTitle = jobTitle
        }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window = webView.window {
            operation.runModal(
                for: window,
                delegate: nil,
                didRun: nil,
                contextInfo: nil
            )
        } else {
            operation.run()
        }
    }
#endif

    // MARK: Scroll position

    public func getScrollRatio() async -> Double {
        let js = """
        (function() {
            var el = document.scrollingElement || document.documentElement;
            var max = el.scrollHeight - el.clientHeight;
            return max > 0 ? (el.scrollTop / max) : 0;
        })();
        """
        guard let value = await evaluate(js) as? NSNumber else { return 0 }
        return value.doubleValue
    }

    public func setScrollRatio(_ ratio: Double) async {
        let js = """
        (function() {
            var el = document.scrollingElement || document.documentElement;
            var max = el.scrollHeight - el.clientHeight;
            el.scrollTop = max * \(ratio);
        })();
        """
        await run(js)
    }

    // MARK: Sourcepos sync (editor <-> preview mapping via data-sourcepos)

    /// Source line of the topmost visible rendered block, or nil before the
    /// first sourcepos render.
    public func topVisibleSourceLine() async -> Int? {
        guard let value = await evaluate("window.tvmv.topVisibleSourceLine()") as? NSNumber else {
            return nil
        }
        return value.intValue
    }

    /// Scroll the block containing `line` to the top of the preview.
    public func scrollToSourceLine(_ line: Int) async {
        await run("window.tvmv.scrollToSourceLine(\(line));")
    }

    /// Scroll the block containing `line` into view only if it is offscreen.
    public func revealSourceLine(_ line: Int) async {
        await run("window.tvmv.revealSourceLine(\(line));")
    }

    /// Move keyboard focus to the web view (leaving edit mode).
    public func focus() {
        guard let webView else { return }
#if os(macOS)
        webView.window?.makeFirstResponder(webView)
#else
        webView.becomeFirstResponder()
#endif
    }

    // MARK: JS helpers

    @discardableResult
    private func evaluate(_ js: String) async -> Any? {
        guard let webView else { return nil }
        do {
            // The async evaluateJavaScript has no default contentWorld; pass one.
            return try await webView.evaluateJavaScript(js, in: nil, contentWorld: .page)
        } catch {
            return nil
        }
    }

    private func run(_ js: String) async {
        _ = await evaluate(js)
    }
}
