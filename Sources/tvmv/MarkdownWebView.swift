import TVMVCore
import SwiftUI
import AppKit
import WebKit

/// Delivers messages from the JS side back to SwiftUI.
/// A delegate closure is sufficient for our needs.
struct MarkdownWebViewCallbacks {
    var onOutline: (@MainActor ([OutlineItem]) -> Void)?
    var onRenderComplete: (@MainActor () -> Void)?
    var onError: (@MainActor (String) -> Void)?
    /// Fired when the template page finishes loading (boot.js is live and the
    /// `window.tvmv` API is callable). The owner renders content on this signal.
    var onReady: (@MainActor () -> Void)?
    /// Fired when the user clicks a rendered block; carries the block's
    /// 1-based source line (from data-sourcepos) for preview→editor jumps.
    var onSourceClick: (@MainActor (Int) -> Void)?
}

/// NSViewRepresentable wrapping a WKWebView that hosts the markdown renderer.
struct MarkdownWebView: NSViewRepresentable {

    /// Base directory of bundled web resources (the `web/` folder).
    let appWebDir: URL

    /// Directory of the currently-open document (for `tvmv-asset://doc/...`).
    var docDir: URL?

    /// Callbacks back into SwiftUI.
    var callbacks: MarkdownWebViewCallbacks = .init()

    /// Lets the owning view grab a handle to the controller for imperative calls.
    var onMakeController: (@MainActor (MarkdownWebController) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(callbacks: callbacks)
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator

        let configuration = WKWebViewConfiguration()

        // Register the custom asset scheme handler.
        let handler = AssetSchemeHandler(appBaseDir: appWebDir, docBaseDir: docDir)
        coordinator.schemeHandler = handler
        configuration.setURLSchemeHandler(handler, forURLScheme: AssetSchemeHandler.scheme)

        // JS -> Swift bridge: messages named "tvmv".
        configuration.userContentController.add(coordinator, name: "tvmv")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true   // trackpad pinch-to-zoom
        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        // Hand a controller to the owner for imperative commands.
        let controller = MarkdownWebController(coordinator: coordinator)
        coordinator.controller = controller
        onMakeController?(controller)

        // Load the template once.
        if let templateURL = URL(string: "\(AssetSchemeHandler.scheme)://app/template.html") {
            webView.load(URLRequest(url: templateURL))
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Keep the scheme handler's document directory in sync.
        context.coordinator.schemeHandler?.setDocumentDirectory(docDir)
        context.coordinator.callbacks = callbacks
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var callbacks: MarkdownWebViewCallbacks
        weak var webView: WKWebView?
        var schemeHandler: AssetSchemeHandler?
        var controller: MarkdownWebController?

        init(callbacks: MarkdownWebViewCallbacks) {
            self.callbacks = callbacks
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
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
                    callbacks.onSourceClick?(line)
                }

            case "error":
                let msg = dict["message"] as? String ?? "Unknown error"
                callbacks.onError?(msg)

            default:
                break
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The template page (and boot.js) has loaded; `window.tvmv` is callable.
            callbacks.onReady?()
        }

        func webView(
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

            // External links: open in the user's browser / mail client.
            if scheme == "http" || scheme == "https" || scheme == "mailto" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.cancel)
        }
    }
}

/// Imperative command surface the app calls. All work hops to the main actor
/// because WKWebView and the bridge are main-actor isolated.
@MainActor
final class MarkdownWebController {
    private weak var coordinator: MarkdownWebView.Coordinator?

    init(coordinator: MarkdownWebView.Coordinator) {
        self.coordinator = coordinator
    }

    private var webView: WKWebView? { coordinator?.webView }

    // MARK: Content

    func setContent(bodyHTML: String, docBaseHref: String) async {
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
    func waitForLayoutSettle() async {
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

    func applyStyle(json: String) async {
        let js = "window.tvmv.applyStyle(\(JSString.literal(json)));"
        await run(js)
    }

    /// Inject the user's custom stylesheet (overrides the theme). Empty clears it.
    func setUserCSS(_ css: String) async {
        let js = "window.tvmv.applyUserCSS(\(JSString.literal(css)));"
        await run(js)
    }

    /// The page's effective background color (e.g. "rgb(0, 133, 124)"), so the
    /// app can tint its window chrome to match the theme.
    func pageBackgroundColor() async -> String? {
        await evaluate("getComputedStyle(document.body).backgroundColor") as? String
    }

    func scrollToAnchor(_ anchor: String) async {
        let js = "window.tvmv.scrollToAnchor(\(JSString.literal(anchor)));"
        await run(js)
    }

    // MARK: Find (JS-backed via window.tvmv: returns total count + 1-based index)

    struct FindResult: Sendable, Equatable {
        var count: Int
        var index: Int
    }

    @discardableResult
    func find(_ string: String) async -> FindResult {
        await findCall("window.tvmv.find(\(JSString.literal(string)))")
    }

    @discardableResult
    func findNext(forward: Bool) async -> FindResult {
        await findCall("window.tvmv.findNext(\(forward ? 1 : -1))")
    }

    func clearFind() async {
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

    // MARK: Print (surfaces Save-as-PDF)

    func printDocument(jobTitle: String? = nil) {
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

    // MARK: Scroll position

    func getScrollRatio() async -> Double {
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

    func setScrollRatio(_ ratio: Double) async {
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
    func topVisibleSourceLine() async -> Int? {
        guard let value = await evaluate("window.tvmv.topVisibleSourceLine()") as? NSNumber else {
            return nil
        }
        return value.intValue
    }

    /// Scroll the block containing `line` to the top of the preview.
    func scrollToSourceLine(_ line: Int) async {
        await run("window.tvmv.scrollToSourceLine(\(line));")
    }

    /// Scroll the block containing `line` into view only if it is offscreen.
    func revealSourceLine(_ line: Int) async {
        await run("window.tvmv.revealSourceLine(\(line));")
    }

    /// Move keyboard focus to the web view (leaving edit mode).
    func focus() {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
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
