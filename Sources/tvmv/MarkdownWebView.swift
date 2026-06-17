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
        let js = "window.tvmv.render(\(Self.jsString(bodyHTML)), \(Self.jsString(docBaseHref)));"
        await run(js)
    }

    func applyStyle(json: String) async {
        let js = "window.tvmv.applyStyle(\(Self.jsString(json)));"
        await run(js)
    }

    func scrollToAnchor(_ anchor: String) async {
        let js = "window.tvmv.scrollToAnchor(\(Self.jsString(anchor)));"
        await run(js)
    }

    // MARK: Find (JS-backed via window.tvmv: returns total count + 1-based index)

    struct FindResult: Sendable, Equatable {
        var count: Int
        var index: Int
    }

    @discardableResult
    func find(_ string: String) async -> FindResult {
        await findCall("window.tvmv.find(\(Self.jsString(string)))")
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

    func printDocument() {
        guard let webView else { return }
        let printInfo = NSPrintInfo.shared
        let operation = webView.printOperation(with: printInfo)
        operation.view?.frame = webView.bounds
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

    /// JSON-encode a Swift string into a safe JS string literal.
    private static func jsString(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\"\""
    }
}
