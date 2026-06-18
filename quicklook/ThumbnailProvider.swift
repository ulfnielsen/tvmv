import Cocoa
import WebKit
import QuickLookThumbnailing

/// QuickLook thumbnail extension principal class.
///
/// Renders a Markdown file through TVMV's existing pipeline:
///   bytes -> MarkdownText.decode -> renderHTML (cmark-gfm) -> WKWebView
/// then snapshots the top of a PAGE-sized web view (820 x ~1060, an 8.5:11
/// sheet) and scales that snapshot DOWN to fill the thumbnail. Because the
/// page is wide and the thumbnail small, body text becomes tiny and several
/// lines/paragraphs are visible — a "page overview" rather than a single huge
/// heading (which is what the preview-derived auto thumbnail produced).
///
/// The `@objc(ThumbnailProvider)` name MUST match the Info.plist
/// `NSExtensionPrincipalClass`. WKWebView is main-thread only, so all web
/// work is dispatched to the main queue; thumbnail providers may be invoked
/// off the main thread.
@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {

    // The page we render+snapshot. 8.5:11 (US Letter) aspect, wide enough that
    // body text shrinks to a realistic "page of paper" scale in the thumbnail.
    private static let pageWidth: CGFloat = 820
    private static let pageHeight: CGFloat = 820 * 11.0 / 8.5  // ≈ 1061

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL

        // 1. Read + decode + render off the main thread is fine (pure CPU); the
        //    WKWebView work below is forced onto main.
        let body: String
        do {
            let data = try Data(contentsOf: url)
            let decoded = MarkdownText.decode(data)
            body = renderHTML(decoded.text)
        } catch {
            handler(nil, error)
            return
        }

        guard let resourceURL = Bundle(for: ThumbnailProvider.self).resourceURL else {
            handler(nil, ThumbnailError.missingResources)
            return
        }
        let webDir = resourceURL.appendingPathComponent("web")
        let docDir = url.deletingLastPathComponent()

        // 2. All WKWebView interaction must happen on the main thread.
        DispatchQueue.main.async {
            let renderer = PageRenderer(
                bodyHTML: body,
                appBaseDir: webDir,
                docBaseDir: docDir,
                pageSize: NSSize(width: Self.pageWidth, height: Self.pageHeight)
            )
            // Keep a strong ref for the duration of the async render.
            self.activeRenderer = renderer
            renderer.render { [weak self] image in
                self?.activeRenderer = nil
                guard let image else {
                    handler(nil, ThumbnailError.snapshotFailed)
                    return
                }
                let reply = Self.makeReply(snapshot: image, request: request)
                handler(reply, nil)
            }
        }
    }

    // Strong ref so the renderer + its web view + delegates survive the async
    // render (the provider instance outlives the call via QuickLook's XPC host).
    private var activeRenderer: PageRenderer?

    /// Build a QLThumbnailReply whose context is a portrait page that fits
    /// `request.maximumSize`, honoring `request.scale`. The page snapshot is
    /// drawn scaled to FILL the context width, top-aligned (so the thumbnail
    /// shows the top of the document, like the first part of a page).
    private static func makeReply(
        snapshot: NSImage,
        request: QLFileThumbnailRequest
    ) -> QLThumbnailReply {
        let maxSize = request.maximumSize           // points
        let scale = request.scale                   // pixels per point

        // Fit an 8.5:11 portrait page inside the requested maximum (in points).
        let pageAspect = pageHeight / pageWidth      // height / width ≈ 1.294
        var w = maxSize.width
        var h = w * pageAspect
        if h > maxSize.height {
            h = maxSize.height
            w = h / pageAspect
        }
        // QLThumbnailReply(contextSize:) is in POINTS; QuickLook multiplies by
        // request.scale internally for the backing store. We pass points.
        let contextSize = CGSize(width: max(1, w), height: max(1, h))

        return QLThumbnailReply(contextSize: contextSize) { (ctx: CGContext) -> Bool in
            // Scale the wide page snapshot DOWN to fill the context width.
            // Top-aligned: anchor the snapshot's TOP to the context's TOP so we
            // see the beginning of the document. The CGContext origin is
            // bottom-left, so the page top sits at y = contextSize.height - drawnHeight.
            let snapPxW = snapshot.size.width > 0 ? snapshot.size.width : pageWidth
            let snapPxH = snapshot.size.height > 0 ? snapshot.size.height : pageHeight

            // Fill width; preserve the snapshot's own aspect for the drawn height.
            let drawScale = contextSize.width / snapPxW
            let drawnHeight = snapPxH * drawScale

            ctx.saveGState()
            // White page background (in case the snapshot has transparency at edges).
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: contextSize))

            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx

            let destRect = CGRect(
                x: 0,
                y: contextSize.height - drawnHeight,  // top-align
                width: contextSize.width,
                height: drawnHeight
            )
            snapshot.draw(
                in: destRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )

            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            _ = scale  // scale is applied by QuickLook to the context backing store
            return true
        }
    }

    enum ThumbnailError: Error { case missingResources, snapshotFailed }
}

/// Drives an offscreen WKWebView through TVMV's render pipeline and snapshots
/// the top page-rect once `window.tvmv` posts `renderComplete` (with a timed
/// fallback). All methods are main-thread only.
@MainActor
private final class PageRenderer: NSObject {

    private let bodyHTML: String
    private let pageSize: NSSize
    private let schemeHandler: PreviewAssetSchemeHandler

    private var window: NSWindow?
    private var webView: WKWebView!
    private var navDelegate: NavDelegate?
    private var messageHandler: MessageHandler?

    private var completion: ((NSImage?) -> Void)?
    private var fallbackTimer: Timer?
    private var didFinish = false

    init(bodyHTML: String, appBaseDir: URL, docBaseDir: URL?, pageSize: NSSize) {
        self.bodyHTML = bodyHTML
        self.pageSize = pageSize
        self.schemeHandler = PreviewAssetSchemeHandler(appBaseDir: appBaseDir, docBaseDir: docBaseDir)
        super.init()
    }

    func render(completion: @escaping (NSImage?) -> Void) {
        self.completion = completion

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "tvmv-asset")

        let mh = MessageHandler { [weak self] type in
            if type == "renderComplete" { self?.snapshotAndFinish() }
        }
        self.messageHandler = mh
        config.userContentController.add(mh, name: "tvmv")

        let frame = NSRect(origin: .zero, size: pageSize)
        let wv = WKWebView(frame: frame, configuration: config)
        self.webView = wv

        // WKWebView needs to be in a window to lay out + snapshot reliably.
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.contentView = wv
        // Keep it offscreen / invisible.
        win.alphaValue = 0
        win.orderOut(nil)
        self.window = win

        let nav = NavDelegate { [weak self] in self?.injectDocument() }
        self.navDelegate = nav
        wv.navigationDelegate = nav

        guard let templateURL = URL(string: "tvmv-asset://app/template.html") else {
            finish(nil)
            return
        }
        wv.load(URLRequest(url: templateURL))

        // Fallback: snapshot after ~2s even if renderComplete never posts.
        // The timer is scheduled on (and fires on) the main run loop, so the
        // closure body is main-actor isolated in practice; assert that so the
        // @MainActor `snapshotAndFinish()` call is statically sound.
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapshotAndFinish() }
        }
        self.fallbackTimer = t
    }

    private func injectDocument() {
        // Reading-theme typography (mirrors the preview defaults). fullWidth
        // false keeps a measured column, which reads like a page of prose.
        let style = """
        window.tvmv.applyStyle({theme:'light',bodyFont:'Source Serif 4',\
        monoFont:'Menlo',baseSize:16,measure:80,fullWidth:false})
        """
        webView.evaluateJavaScript(style, completionHandler: nil)

        let jsonHTML = Self.jsString(bodyHTML)
        let jsonBase = Self.jsString("tvmv-asset://doc/")
        webView.evaluateJavaScript("window.tvmv.render(\(jsonHTML), \(jsonBase))", completionHandler: nil)
    }

    private func snapshotAndFinish() {
        guard !didFinish else { return }
        // Give layout a beat to settle, then snapshot the top page-rect.
        let cfg = WKSnapshotConfiguration()
        cfg.rect = NSRect(x: 0, y: 0, width: pageSize.width, height: pageSize.height)
        cfg.snapshotWidth = NSNumber(value: Double(pageSize.width))

        webView.takeSnapshot(with: cfg) { [weak self] image, _ in
            self?.finish(image)
        }
    }

    private func finish(_ image: NSImage?) {
        guard !didFinish else { return }
        didFinish = true
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        window?.orderOut(nil)
        let handler = completion
        completion = nil
        handler?(image)
    }

    /// Encode a Swift string as a JavaScript string literal via JSON.
    private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: []))
            ?? Data("[\"\"]".utf8)
        var json = String(data: data, encoding: .utf8) ?? "[\"\"]"
        json.removeFirst()
        json.removeLast()
        return json
    }
}

/// WKNavigationDelegate that fires a callback once the template finishes loading.
private final class NavDelegate: NSObject, WKNavigationDelegate {
    private let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }
}

/// Bridges boot.js `postMessage` payloads back to the renderer.
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
