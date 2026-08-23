import XCTest

/// Launch smoke: the app reaches the document browser / launch scene.
///
/// The rendering pipeline itself is covered end-to-end by the hosted unit
/// test PreviewPipelineTests (real WKWebView + bundled assets + bridges);
/// automating Apple's document-browser chrome proved unstable under the
/// iOS 26 launch scene (window-relative frames fail hit-testing, and browser
/// state persists across launches), so document open/create stays a manual
/// check. Known issue: the launch scene's "Create Document" fails with
/// NSFileProvider -1005 on simulators without an iCloud account; retest
/// creation on a signed-in device.
final class DocumentFlowUITests: XCTestCase {
    @MainActor
    func testLaunchReachesDocumentBrowser() throws {
        let app = XCUIApplication()
        app.launch()

        // Fresh install shows the launch scene's Create Document; a relaunch
        // may restore the full browser instead — accept either signal.
        let create = app.buttons["Create Document"].firstMatch
        let browse = app.buttons["Browse"].firstMatch
        let recents = app.buttons["Recents"].firstMatch

        let reached = create.waitForExistence(timeout: 15)
            || browse.waitForExistence(timeout: 5)
            || recents.waitForExistence(timeout: 5)
        XCTAssertTrue(reached, "app should reach the document browser UI")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }
}
