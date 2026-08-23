import XCTest
import WebKit
@testable import TVMV
import TVMVCore

/// Drives the REAL editor pipeline inside the app process on the simulator:
/// editor.html + CodeMirror load through the scheme handler, a genuine editor
/// transaction is dispatched, and the settled edit arrives as a compact patch
/// over the bridge — the same path user keystrokes take.
@MainActor
final class EditorPipelineTests: XCTestCase {

    func testEditorTransactionArrivesAsPatch() async throws {
        let readyExp = expectation(description: "editor ready")
        let patchExp = expectation(description: "patch posted")
        var patches: [TextPatcher.Patch] = []
        var reportedLength = -1

        let coordinator = EditorCoordinator(callbacks: .init(
            onReady: { _ in readyExp.fulfill() },
            onTextPatch: { p, length in
                patches = p
                reportedLength = length
                patchExp.fulfill()
            },
            onError: { XCTFail("editor bridge error: \($0)") }
        ))

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 400),
            configuration: coordinator.makeConfiguration(appWebDir: WebResources.baseURL))

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIViewController()
        window.rootViewController = host
        host.view.addSubview(webView)
        window.makeKeyAndVisible()

        let bridge = coordinator.attach(webView)
        await fulfillment(of: [readyExp], timeout: 20)

        await bridge.setText("hello", resetHistory: true)
        let seeded = await bridge.getText()
        XCTAssertEqual(seeded, "hello")

        // A real CodeMirror transaction (not setText, which suppresses the
        // patch channel by design). Trailing 0 keeps the async evaluator away
        // from a nil result.
        _ = try await webView.evaluateJavaScript(
            "window.tvmvEditor._view.dispatch({changes: {from: 5, insert: ' world'}}); 0",
            in: nil, contentWorld: .page)

        await fulfillment(of: [patchExp], timeout: 10)
        XCTAssertEqual(patches, [TextPatcher.Patch(from: 5, to: 5, insert: " world")])
        XCTAssertEqual(reportedLength, 11)

        // And the patch applies to the native side exactly.
        XCTAssertEqual(TextPatcher.apply(patches, to: "hello",
                                         expectedUTF16Length: reportedLength),
                       "hello world")
    }
}
