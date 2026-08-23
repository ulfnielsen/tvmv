import XCTest
import WebKit
@testable import TVMV
import TVMVCore

/// Drives the REAL preview pipeline inside the app process on the simulator:
/// bundled web assets resolved via WebResources, template.html loaded through
/// AssetSchemeHandler, markdown rendered by cmark → boot.js, and the outline
/// posted back over the message bridge. Everything the document browser flow
/// exercises except the browser chrome itself.
@MainActor
final class PreviewPipelineTests: XCTestCase {

    func testRenderPipelineProducesOutlineAndBackground() async throws {
        let readyExp = expectation(description: "template ready")
        let outlineExp = expectation(description: "outline posted")
        var outline: [OutlineItem] = []

        let coordinator = PreviewCoordinator(callbacks: .init(
            onOutline: { items in
                outline = items
                outlineExp.fulfill()
            },
            onError: { XCTFail("bridge error: \($0)") },
            onReady: { readyExp.fulfill() }
        ))

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            configuration: coordinator.makeConfiguration(
                appWebDir: WebResources.baseURL, docDir: nil))

        // WebKit needs to live in a window to load and lay out.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let host = UIViewController()
        window.rootViewController = host
        host.view.addSubview(webView)
        window.makeKeyAndVisible()

        let controller = coordinator.attach(webView)
        await fulfillment(of: [readyExp], timeout: 20)

        let html = renderHTML("# Alpha\n\nBody text.\n\n## Beta\n", sourcePos: true)
        await controller.setContent(bodyHTML: html, docBaseHref: "tvmv-asset://doc/")
        await fulfillment(of: [outlineExp], timeout: 20)

        XCTAssertEqual(outline.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(outline.map(\.level), [1, 2])

        // The theme painted the page (paper background), proving app.css
        // resolved through the scheme handler too.
        await controller.applyStyle(json: AppSettings.shared.styleJSON)
        let background = await controller.pageBackgroundColor()
        XCTAssertNotNil(background)
        XCTAssertNotEqual(background, "rgba(0, 0, 0, 0)",
                          "app.css should have painted a background")
    }
}
