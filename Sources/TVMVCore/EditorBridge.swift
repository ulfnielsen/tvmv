import SwiftUI
import WebKit

/// A captured editor location, used to restore cursor + scroll when the
/// editor pane is closed and reopened. Offsets are UTF-16 code units (both
/// CodeMirror positions and Swift's NSString-view lengths count UTF-16).
public struct EditorPosition: Sendable {
    public var cursorOffset: Int   // clamped on restore
    public var topLine: Int        // 1-based

    public init(cursorOffset: Int, topLine: Int) {
        self.cursorOffset = cursorOffset
        self.topLine = topLine
    }
}

/// Events pushed by the editor page. All delivered on the main actor.
public struct EditorBridgeCallbacks {
    public var onReady: (@MainActor (EditorBridge) -> Void)?
    /// Settled edits as compact patches (UTF-16 offsets against the document
    /// as of the previous flush) plus the editor's post-change doc length.
    public var onTextPatch: (@MainActor ([TextPatcher.Patch], Int) -> Void)?
    /// (1-based line, UTF-16 offset)
    public var onCursorMoved: (@MainActor (Int, Int) -> Void)?
    /// 1-based first visible line
    public var onScrolled: (@MainActor (Int) -> Void)?
    /// Editor page failed to load, or an uncaught JS error occurred — shown
    /// to the user via the window's error banner.
    public var onError: (@MainActor (String) -> Void)?

    public init(
        onReady: (@MainActor (EditorBridge) -> Void)? = nil,
        onTextPatch: (@MainActor ([TextPatcher.Patch], Int) -> Void)? = nil,
        onCursorMoved: (@MainActor (Int, Int) -> Void)? = nil,
        onScrolled: (@MainActor (Int) -> Void)? = nil,
        onError: (@MainActor (String) -> Void)? = nil
    ) {
        self.onReady = onReady
        self.onTextPatch = onTextPatch
        self.onCursorMoved = onCursorMoved
        self.onScrolled = onScrolled
        self.onError = onError
    }
}

/// Command surface into the CodeMirror page, mirroring MarkdownWebController's
/// role for the preview. All calls are async JS round-trips; they no-op until
/// the page is loaded (evaluate failures return nil).
@MainActor
public final class EditorBridge {
    weak var webView: WKWebView?

    public func setText(_ text: String, resetHistory: Bool) async {
        await run("window.tvmvEditor.setText(\(JSString.literal(text)), \(resetHistory));")
    }

    public func scrollToLine(_ line: Int, placeCursor: Bool) async {
        await run("window.tvmvEditor.scrollToLine(\(line), \(placeCursor));")
    }

    public func restore(_ p: EditorPosition) async {
        await run("window.tvmvEditor.restore(\(p.cursorOffset), \(p.topLine));")
    }

    /// The authoritative document, for save flushes. Nil when the page is gone.
    public func getText() async -> String? {
        await evaluate("window.tvmvEditor.getText()") as? String
    }

    public func applyStyle(json: String) async {
        await run("window.tvmvEditor.applyStyle(\(JSString.literal(json)));")
    }

    /// Keyboard focus: the web view first, then CodeMirror inside it.
    public func focus() {
        guard let webView else { return }
#if os(macOS)
        webView.window?.makeFirstResponder(webView)
#else
        webView.becomeFirstResponder()
#endif
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

/// Shared (Mac + iOS) coordinator for the editor web view: builds the
/// configuration, receives the page's messages, and hands the platform
/// wrapper an EditorBridge once a web view is attached.
@MainActor
public final class EditorCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    public var callbacks: EditorBridgeCallbacks
    weak var webView: WKWebView?
    var bridge: EditorBridge?

    public init(callbacks: EditorBridgeCallbacks) {
        self.callbacks = callbacks
    }

    /// Build the configuration (scheme handler + message channel) the host
    /// web view must be created with.
    public func makeConfiguration(appWebDir: URL) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        let handler = AssetSchemeHandler(appBaseDir: appWebDir, docBaseDir: nil)
        configuration.setURLSchemeHandler(handler, forURLScheme: AssetSchemeHandler.scheme)
        configuration.userContentController.add(self, name: "tvmvEditor")
        return configuration
    }

    /// Wire a platform-created web view and start loading the editor page.
    public func attach(_ webView: WKWebView) -> EditorBridge {
        webView.navigationDelegate = self
        self.webView = webView
        let bridge = EditorBridge()
        bridge.webView = webView
        self.bridge = bridge
        if let url = URL(string: "\(AssetSchemeHandler.scheme)://app/editor.html") {
            webView.load(URLRequest(url: url))
        }
        return bridge
    }

    /// Explicit teardown: unregister the message handler and drop callbacks
    /// so a closing page's late events can never reach the model.
    public func detach(_ webView: WKWebView) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "tvmvEditor")
        callbacks = EditorBridgeCallbacks()
    }

    // MARK: WKNavigationDelegate — editor page load failures

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        callbacks.onError?("Editor failed to load: \(error.localizedDescription)")
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        callbacks.onError?("Editor failed to load: \(error.localizedDescription)")
    }

    public nonisolated func userContentController(
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
            case "textPatch":
                if let raw = dict["patches"] as? [[Any]],
                   let length = dict["length"] as? Int {
                    let patches = raw.compactMap { entry -> TextPatcher.Patch? in
                        guard entry.count == 3,
                              let from = entry[0] as? Int,
                              let to = entry[1] as? Int,
                              let insert = entry[2] as? String
                        else { return nil }
                        return TextPatcher.Patch(from: from, to: to, insert: insert)
                    }
                    // A triple that failed to parse means the payload is
                    // incoherent — deliver an empty list so the model
                    // resyncs rather than applying a partial edit.
                    callbacks.onTextPatch?(patches.count == raw.count ? patches : [], length)
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
