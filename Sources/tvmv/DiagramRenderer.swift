import TVMVCore
import TVMVNativeText
import AppKit
import WebKit

/// Renders Mermaid diagrams and display math for the native view: one
/// offscreen web page (diagram.html, with the bundled Mermaid and KaTeX)
/// lays each out, and WebKit captures it as a PDF, so the picture is
/// vector and looks as it does in the web reader and in print. One
/// diagram renders at a time; results are cached for the app's lifetime.
@MainActor
final class DiagramRenderer: NSObject, WKNavigationDelegate {
    static let shared = DiagramRenderer()

    /// What a picture depends on: its source and the theme it is drawn in.
    struct Key: Hashable {
        var kind: MarkdownLayout.Diagram.Kind
        var source: String
        var dark: Bool
        /// Text color of math, as CSS.
        var color: String
        var fontSize: CGFloat

        init(_ diagram: MarkdownLayout.Diagram, theme: NativeTheme) {
            kind = diagram.kind
            source = diagram.source
            dark = theme.isDark
            color = Self.css(theme.ink)
            fontSize = theme.body.pointSize
        }

        static func css(_ color: NSColor) -> String {
            let c = color.usingColorSpace(.sRGB) ?? .black
            return String(format: "#%02X%02X%02X", Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5),
                          Int(c.blueComponent * 255 + 0.5))
        }
    }

    enum State { case rendering, rendered(NSImage), failed }

    /// A document is untrusted: cap what one diagram may cost.
    var maxSourceLength = 50_000
    var maxSide: CGFloat = 8_000
    var timeout: Duration = .seconds(10)

    private var states: [Key: State] = [:]
    private var waiting: [Key: [@MainActor (Key) -> Void]] = [:]
    private var queue: [Key] = []
    private var webView: WKWebView?
    private var window: NSWindow?
    private var pageReady = false
    /// The render in flight.
    private var current: Int?
    /// Renders started (observability: each key renders once).
    private(set) var rendersStarted = 0

    func state(for key: Key) -> State? { states[key] }

    func image(for key: Key) -> NSImage? {
        if case .rendered(let image) = states[key] { return image }
        return nil
    }

    /// Render every key not yet requested; `onSettled` runs once for each
    /// key this call is waiting on, when it is rendered or has failed.
    func request(_ keys: [Key], onSettled: @escaping @MainActor (Key) -> Void) {
        for key in Set(keys) {
            switch states[key] {
            case .rendered, .failed: continue
            case .rendering: waiting[key, default: []].append(onSettled)
            case nil:
                waiting[key, default: []].append(onSettled)
                if key.source.utf16.count > maxSourceLength { settle(key, nil); continue }
                states[key] = .rendering
                queue.append(key)
            }
        }
        pump()
    }

    // MARK: Rendering

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        guard pageReady, let webView else { loadPage(); return }
        let key = queue.removeFirst()
        rendersStarted += 1
        let job = rendersStarted
        current = job
        Task {
            let image = await render(key, in: webView)
            guard current == job else { return }   // timed out meanwhile
            current = nil
            settle(key, image)
            pump()
        }
        Task {
            try? await Task.sleep(for: timeout)
            guard current == job else { return }
            // Stuck (a pathological diagram): give up on it and start a fresh page.
            current = nil
            settle(key, nil)
            resetPage()
            pump()
        }
    }

    private func render(_ key: Key, in webView: WKWebView) async -> NSImage? {
        do {
            let size = try await webView.callAsyncJavaScript(
                "return await renderDiagram(kind, source, dark, color, size)",
                arguments: ["kind": key.kind.rawValue, "source": key.source, "dark": key.dark,
                            "color": key.color, "size": key.fontSize],
                contentWorld: .page) as? [String: Any]
            guard let width = (size?["width"] as? NSNumber).map({ CGFloat(truncating: $0) }),
                  let height = (size?["height"] as? NSNumber).map({ CGFloat(truncating: $0) }),
                  width > 0, height > 0, width <= maxSide, height <= maxSide else { return nil }
            if webView.frame.width < width || webView.frame.height < height {
                webView.frame.size = NSSize(width: max(webView.frame.width, width), height: max(webView.frame.height, height))
            }
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
            let pdf = try await webView.pdf(configuration: configuration)
            guard let image = NSImage(data: pdf), image.size.width > 0 else { return nil }
            image.size = NSSize(width: width, height: height)
            return image
        } catch {
            return nil
        }
    }

    private func settle(_ key: Key, _ image: NSImage?) {
        states[key] = image.map { .rendered($0) } ?? .failed
        let callbacks = waiting.removeValue(forKey: key) ?? []
        callbacks.forEach { $0(key) }
    }

    // MARK: The page

    private func loadPage() {
        guard webView == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")   // a transparent picture
        webView.navigationDelegate = self
        window.contentView!.addSubview(webView)
        self.window = window
        self.webView = webView
        let web = WebResources.baseURL
        webView.loadFileURL(web.appendingPathComponent("diagram.html"), allowingReadAccessTo: web)
    }

    private func resetPage() {
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        window = nil
        pageReady = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        pageReady = true
        pump()
    }

    /// The page never navigates anywhere else (a diagram's link included).
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url?.isFileURL == true && action.targetFrame?.isMainFrame == true
            && action.request.url?.lastPathComponent == "diagram.html" ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { pageFailed(webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageFailed(webView)
    }

    /// The page can't load: every queued diagram shows as source.
    private func pageFailed(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        let failed = queue
        queue = []
        failed.forEach { settle($0, nil) }
        resetPage()
    }
}
