import XCTest
@testable import tvmv

final class MarkdownRendererTests: XCTestCase {
    func testHeadingAndEmphasis() {
        let html = renderHTML("# Title\n\nsome **bold** text")
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
    }
    func testTableExtension() {
        let html = renderHTML("| a | b |\n|---|---|\n| 1 | 2 |")
        XCTAssertTrue(html.contains("<table>"))
    }
    func testStrikethroughAndTaskListAndAutolink() {
        let html = renderHTML("~~gone~~\n\n- [x] done\n- [ ] todo\n\nhttps://example.com")
        XCTAssertTrue(html.contains("<del>gone</del>"))
        XCTAssertTrue(html.contains("type=\"checkbox\""))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\""))
    }
    func testFencedCodeCarriesLanguageClass() {
        let html = renderHTML("```swift\nlet x = 1\n```")
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"))
    }
    func testHeadingHasNoIdByDefault() {
        // Anchors are assigned in JS; cmark-gfm emits none.
        XCTAssertFalse(renderHTML("# Hello").contains("<h1 id"))
    }
    func testSourcePosEmitsDataSourcepos() {
        let html = renderHTML("# Title\n\npara\n\n| a |\n|---|\n| 1 |\n", sourcePos: true)
        XCTAssertTrue(html.contains("<h1 data-sourcepos=\"1:1-1:7\">"))
        XCTAssertTrue(html.contains("<p data-sourcepos=\"3:1-3:4\">"))
        // GFM extension blocks must carry sourcepos too (spec risk check).
        XCTAssertTrue(html.contains("<table data-sourcepos="))
    }
    func testSourcePosDefaultsOffAndOutputUnchanged() {
        // QuickLook compiles this file directly; the default must not change output.
        XCTAssertFalse(renderHTML("# Title\n\npara").contains("data-sourcepos"))
    }
}
