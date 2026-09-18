import XCTest
import WebKit
#if os(macOS)
import AppKit
#endif
@testable import TVMVCore

/// In-document links (`[x](#heading)`) must scroll the rendered preview to the
/// heading rather than navigate the web view away from the template page.
///
/// The preview injects `<base href="tvmv-asset://doc/">` so relative image
/// links resolve against the document, which also makes a bare `#fragment`
/// resolve to a *different* document; boot.js has to handle those clicks.
@MainActor
final class PreviewFragmentLinkTests: XCTestCase {
    private var coordinator: PreviewCoordinator!
    private var webView: WKWebView!
    private var controller: MarkdownWebController!

    /// Pump the main run loop until `condition` is true or `timeout` elapses.
    /// XCTest holds the main thread during a test, so WebKit's IPC and the
    /// main-actor continuations only progress while we spin it ourselves.
    private func spin(until condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// Run JS to completion on the spun run loop and hand back its result.
    @discardableResult
    private func js(_ script: String) -> Any? {
        var done = false
        var result: Any?
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { outcome in
            result = try? outcome.get()
            done = true
        }
        spin(until: { done })
        return result
    }

    private func awaitVoid(_ body: @escaping () async -> Void) {
        var done = false
        Task { await body(); done = true }
        spin(until: { done })
    }

    private var ready = false
    #if os(macOS)
    private var window: NSWindow?
    #endif

    private func loadPreview() {
        coordinator = PreviewCoordinator(callbacks: .init())
        let docDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvmv-frag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: docDir) }
        // `WebResources.baseURL` keys off Bundle.main, which is the xctest host
        // here; SwiftPM drops the resource bundle beside the test bundle instead.
        let bundleURL = Bundle(for: PreviewCoordinator.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("tvmv_TVMVCore.bundle")
        let webDir = (Bundle(url: bundleURL)?.resourceURL ?? bundleURL).appendingPathComponent("web")
        XCTAssertTrue(FileManager.default.fileExists(atPath: webDir.path), "no web resources at \(webDir.path)")
        let config = coordinator.makeConfiguration(appWebDir: webDir, docDir: docDir)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 400), configuration: config)
        #if os(macOS)
        // Parent the view: WebKit only runs requestAnimationFrame (which
        // waitForLayoutSettle relies on) for a view that is in a window.
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = webView
        window.orderBack(nil)
        self.window = window
        #endif
        controller = coordinator.attach(webView)
        coordinator.callbacks.onReady = { [weak self] in self?.ready = true }
        spin(until: { ready })
        XCTAssertTrue(ready, "template page never became ready")
    }

    func testClickingFragmentLinkScrollsToHeadingWithoutLeavingPage() {
        loadPreview()
        let html = """
        <p><a id="lnk" href="#target">jump</a></p>
        <div style="height:5000px"></div>
        <h2>Target</h2>
        <p>after</p>
        """
        let base = "\(AssetSchemeHandler.scheme)://doc/"
        awaitVoid { await self.controller.setContent(bodyHTML: html, docBaseHref: base) }
        // Not waitForLayoutSettle: requestAnimationFrame never fires for an
        // unexposed test window, so poll the DOM instead.
        spin(until: { (js("return !!document.getElementById('target');") as? Bool) == true })

        let pageBefore = js("return location.href;") as? String
        js("document.getElementById('lnk').click();")
        spin(until: { (js("return window.scrollY;") as? Double ?? 0) > 0 }, timeout: 2)

        let pageAfter = js("return location.href;") as? String
        let scrollY = js("return window.scrollY;") as? Double
        let stillRendered = js("return !!document.getElementById('target');") as? Bool

        XCTAssertEqual(pageBefore, "\(AssetSchemeHandler.scheme)://app/template.html")
        XCTAssertEqual(pageAfter, pageBefore, "the click navigated the web view away from the template")
        XCTAssertEqual(stillRendered, true, "the click replaced the rendered document")
        XCTAssertGreaterThan(scrollY ?? 0, 1000, "page did not scroll to the heading")
    }
}
