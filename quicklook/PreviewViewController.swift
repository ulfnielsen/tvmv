import Cocoa
import WebKit
import QuickLookUI

/// QuickLook preview extension principal class.
///
/// Renders a Markdown file through TVMV's existing pipeline:
///   bytes -> MarkdownText.decode -> renderHTML (cmark-gfm) -> WKWebView
/// using the bundled `web/` assets (template.html / app.css / boot.js + vendor).
///
/// The `@objc(PreviewViewController)` name MUST match the Info.plist
/// `NSExtensionPrincipalClass`. Everything here runs on the main thread; the
/// async render completes when boot.js posts `{type:'renderComplete'}`.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {

    private var webView: WKWebView!
    private var schemeHandler: PreviewAssetSchemeHandler!

    // Strong refs so nothing deallocates mid-async during the preview lifecycle.
    private var navDelegate: NavDelegate?
    private var messageHandler: MessageHandler?
    private var completion: ((Error?) -> Void)?
    private var fallbackTimer: Timer?
    private var didComplete = false
    private var didRender = false
    private var lastCompact: Bool?   // cache so resize doesn't spam JS

    // The rendered body HTML + document base href, captured at prepare time and
    // injected once the template's boot.js has loaded (navigation didFinish).
    private var pendingBodyHTML: String?
    private var pendingDocBase: String?

    override func loadView() {
        // The preview content view fills whatever frame QuickLook gives us.
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.view.autoresizingMask = [.width, .height]
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let wv = webView else { return }
        // macOS derives Finder thumbnails by rendering THIS preview at a small
        // size. Scale responsively: full reading size in the large spacebar
        // window, zoomed out to a page overview when rendered small (thumbnail).
        let zoom = min(1.0, max(0.2, view.bounds.width / 760))
        if abs(wv.pageZoom - zoom) > 0.01 { wv.pageZoom = zoom }
        applyResponsiveLayout()
    }

    /// Adapt the page to the pane size. A small Finder preview pane fills the
    /// width with compact padding (no wasted reading margin — the whole point of
    /// a glance preview); the large spacebar Quick Look window keeps TVMV's
    /// comfortable reading measure + padding. Guarded on `didRender` so the
    /// early layout passes (before boot.js exists) are no-ops.
    private func applyResponsiveLayout() {
        guard didRender, let wv = webView else { return }
        let compact = view.bounds.width < 520
        if compact == lastCompact { return }   // only re-apply on a real change
        lastCompact = compact
        let js: String
        if compact {
            js = "window.tvmv.applyStyle({fullWidth:true});" +
                 "document.documentElement.style.setProperty('--tvmv-pad','22px')"
        } else {
            js = "window.tvmv.applyStyle({fullWidth:false});" +
                 "document.documentElement.style.removeProperty('--tvmv-pad')"
        }
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: QLPreviewingController

    func preparePreviewOfFile(at url: URL,
                              completionHandler handler: @escaping (Error?) -> Void) {
        self.completion = handler

        // 1. Read + decode + render through TVMV's pipeline.
        let body: String
        do {
            let data = try Data(contentsOf: url)
            let decoded = MarkdownText.decode(data)
            body = renderHTML(decoded.text)
        } catch {
            handler(error)
            return
        }

        // 2. Locate the bundled web/ directory inside the appex resources.
        guard let resourceURL = Bundle(for: PreviewViewController.self).resourceURL else {
            handler(PreviewError.missingResources)
            return
        }
        let webDir = resourceURL.appendingPathComponent("web")
        let docDir = url.deletingLastPathComponent()

        // 3. Build the WKWebView with the tvmv-asset:// scheme handler.
        schemeHandler = PreviewAssetSchemeHandler(appBaseDir: webDir, docBaseDir: docDir)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "tvmv-asset")

        let mh = MessageHandler { [weak self] type in
            if type == "renderComplete" { self?.finish(nil) }
        }
        self.messageHandler = mh
        config.userContentController.add(mh, name: "tvmv")

        let wv = WKWebView(frame: self.view.bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        self.webView = wv
        self.view.addSubview(wv)

        let nav = NavDelegate { [weak self] in self?.injectDocument() }
        self.navDelegate = nav
        wv.navigationDelegate = nav

        self.pendingBodyHTML = body
        self.pendingDocBase = "tvmv-asset://doc/"

        // 4. Load the template; boot.js wires up window.tvmv on didFinish.
        guard let templateURL = URL(string: "tvmv-asset://app/template.html") else {
            handler(PreviewError.missingResources)
            return
        }
        wv.load(URLRequest(url: templateURL))

        // 5. Safety net: complete after ~2.5s even if renderComplete never posts
        //    (e.g. sandbox blocked a lazy vendor asset). The view is on-screen by
        //    then, so the preview is still useful.
        let t = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.finish(nil)
        }
        self.fallbackTimer = t
    }

    // MARK: Render injection

    private func injectDocument() {
        guard let body = pendingBodyHTML else { return }
        let base = pendingDocBase ?? "tvmv-asset://doc/"

        // Apply reading-theme typography first (mirrors the app defaults). Width
        // and padding are NOT set here — applyResponsiveLayout() owns those and
        // adapts them to the pane size.
        let style = """
        window.tvmv.applyStyle({theme:'light',bodyFont:'Source Serif 4',\
        monoFont:'Menlo',baseSize:16,measure:80})
        """
        webView.evaluateJavaScript(style, completionHandler: nil)

        // JSON-encode the HTML so it survives as a JS string literal.
        let jsonHTML = Self.jsString(body)
        let jsonBase = Self.jsString(base)
        let render = "window.tvmv.render(\(jsonHTML), \(jsonBase))"
        webView.evaluateJavaScript(render, completionHandler: nil)

        didRender = true
        applyResponsiveLayout()
    }

    private func finish(_ error: Error?) {
        guard !didComplete else { return }
        didComplete = true
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        let handler = completion
        completion = nil
        handler?(error)
    }

    // MARK: Helpers

    /// Encode a Swift string as a JavaScript string literal via JSON.
    private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: []))
            ?? Data("[\"\"]".utf8)
        var json = String(data: data, encoding: .utf8) ?? "[\"\"]"
        // Strip the surrounding array brackets to get the bare string literal.
        json.removeFirst()
        json.removeLast()
        return json
    }

    enum PreviewError: Error { case missingResources }
}

/// WKNavigationDelegate that fires a callback once the template finishes loading.
private final class NavDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }
}

/// Bridges boot.js `postMessage` payloads back to the controller.
private final class MessageHandler: NSObject, WKScriptMessageHandler {
    private let onMessage: (String) -> Void
    init(onMessage: @escaping (String) -> Void) { self.onMessage = onMessage }
    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        if let dict = message.body as? [String: Any],
           let type = dict["type"] as? String {
            onMessage(type)
        }
    }
}
