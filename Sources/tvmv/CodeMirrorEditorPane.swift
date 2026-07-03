import SwiftUI
import AppKit
import WebKit

/// A captured editor location, used to restore cursor + scroll when the
/// editor pane is closed and reopened. Offsets are UTF-16 code units (both
/// CodeMirror positions and Swift's NSString-view lengths count UTF-16).
struct EditorPosition {
    var cursorOffset: Int   // clamped on restore
    var topLine: Int        // 1-based
}

/// Events pushed by the editor page. All delivered on the main actor.
struct EditorBridgeCallbacks {
    var onReady: (@MainActor (EditorBridge) -> Void)?
    var onTextChanged: (@MainActor (String) -> Void)?
    /// (1-based line, UTF-16 offset)
    var onCursorMoved: (@MainActor (Int, Int) -> Void)?
    /// 1-based first visible line
    var onScrolled: (@MainActor (Int) -> Void)?
    /// Editor page failed to load (spec: surface via the existing
    /// errorMessage path; typing into a dead pane visibly does nothing).
    var onError: (@MainActor (String) -> Void)?
}

/// Command surface into the CodeMirror page, mirroring MarkdownWebController's
/// role for the preview. All calls are async JS round-trips; they no-op until
/// the page is loaded (evaluate failures return nil).
@MainActor
final class EditorBridge {
    weak var webView: WKWebView?

    func setText(_ text: String, resetHistory: Bool) async {
        await run("window.tvmvEditor.setText(\(JSString.literal(text)), \(resetHistory));")
    }

    func scrollToLine(_ line: Int, placeCursor: Bool) async {
        await run("window.tvmvEditor.scrollToLine(\(line), \(placeCursor));")
    }

    func restore(_ p: EditorPosition) async {
        await run("window.tvmvEditor.restore(\(p.cursorOffset), \(p.topLine));")
    }

    /// The authoritative document, for save flushes. Nil when the page is gone.
    func getText() async -> String? {
        await evaluate("window.tvmvEditor.getText()") as? String
    }

    func applyStyle(json: String) async {
        await run("window.tvmvEditor.applyStyle(\(JSString.literal(json)));")
    }

    /// Keyboard focus: the web view first, then CodeMirror inside it.
    func focus() {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
        Task { await run("window.tvmvEditor.focusEditor();") }
    }

    @discardableResult
    private func evaluate(_ js: String) async -> Any? {
        guard let webView else { return nil }
        do {
            return try await webView.evaluateJavaScript(js, in: nil, contentWorld: .page)
        } catch {
            return nil
        }
    }

    private func run(_ js: String) async {
        _ = await evaluate(js)
    }
}

/// NSViewRepresentable wrapping the editor WKWebView (a second, dedicated
/// web view — the preview's pipeline is untouched).
struct CodeMirrorEditorPane: NSViewRepresentable {
    /// Base directory of bundled web resources (the `web/` folder).
    let appWebDir: URL
    var callbacks: EditorBridgeCallbacks = .init()
    var onMakeBridge: (@MainActor (EditorBridge) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(callbacks: callbacks) }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()

        let handler = AssetSchemeHandler(appBaseDir: appWebDir, docBaseDir: nil)
        configuration.setURLSchemeHandler(handler, forURLScheme: AssetSchemeHandler.scheme)
        configuration.userContentController.add(coordinator, name: "tvmvEditor")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        let bridge = EditorBridge()
        bridge.webView = webView
        coordinator.bridge = bridge
        onMakeBridge?(bridge)

        if let url = URL(string: "\(AssetSchemeHandler.scheme)://app/editor.html") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.callbacks = callbacks
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // Explicit teardown: unregister the message handler and drop callbacks
        // so a closing page's late events can never reach the model.
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "tvmvEditor")
        coordinator.callbacks = EditorBridgeCallbacks()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var callbacks: EditorBridgeCallbacks
        weak var webView: WKWebView?
        var bridge: EditorBridge?

        init(callbacks: EditorBridgeCallbacks) {
            self.callbacks = callbacks
        }

        // MARK: WKNavigationDelegate — editor page load failures

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            callbacks.onError?("Editor failed to load: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            callbacks.onError?("Editor failed to load: \(error.localizedDescription)")
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // WKScriptMessage delivery is main-thread; hop explicitly for Swift 6.
            MainActor.assumeIsolated {
                guard message.name == "tvmvEditor",
                      let dict = message.body as? [String: Any],
                      let type = dict["type"] as? String
                else { return }

                switch type {
                case "ready":
                    if let bridge { callbacks.onReady?(bridge) }
                case "textChanged":
                    if let text = dict["text"] as? String {
                        callbacks.onTextChanged?(text)
                    }
                case "cursorMoved":
                    if let line = dict["line"] as? Int, let offset = dict["offset"] as? Int {
                        callbacks.onCursorMoved?(line, offset)
                    }
                case "scrolled":
                    if let line = dict["topLine"] as? Int {
                        callbacks.onScrolled?(line)
                    }
                case "error":
                    if let msg = dict["message"] as? String {
                        callbacks.onError?("Editor: \(msg)")
                    }
                default:
                    break
                }
            }
        }
    }
}
