import XCTest
@testable import TVMVCore

final class EditRulesTests: XCTestCase {
    private let text = "# Title\n\nSome *em* text\n\n```\ncode\n```\nafter\n" as NSString
    private var hidden = IndexSet()
    private var isHidden: (Int) -> Bool { { [hidden] in hidden.contains($0) } }

    override func setUp() {
        hidden = IndexSet()
        for marker in MarkdownLayoutParser.parse(text as String).markers {
            hidden.insert(integersIn: marker.range.location..<NSMaxRange(marker.range))
        }
    }

    private func snap(_ location: Int, forward: Bool) -> Int {
        EditRules.snapCaret(location, movingForward: forward, in: text, isHidden: isHidden)
    }

    private func delete(_ location: Int, caret: Int) -> EditRules.DeleteAction {
        EditRules.retargetDelete(NSRange(location: location, length: 1), caret: caret, in: text, isHidden: isHidden)
    }

    func testCaretNeverRestsBeforeAHiddenHeadingPrefix() {
        XCTAssertEqual(snap(0, forward: true), 2)
        XCTAssertEqual(snap(0, forward: false), 2)
        XCTAssertEqual(snap(1, forward: false), 2)
    }

    func testCaretMayRestAtTheInnerEdgeOfFormatting() {
        let em = text.range(of: "*em*")
        XCTAssertEqual(snap(em.location + 1, forward: true), em.location + 1)
        XCTAssertEqual(snap(NSMaxRange(em) - 1, forward: true), NSMaxRange(em) - 1)
    }

    func testCollapsedFenceLinesArePassedInTheDirectionOfTravel() {
        let fence = text.range(of: "```\ncode").location
        let close = text.range(of: "```\nafter").location
        XCTAssertEqual(snap(fence, forward: true), fence + 4)        // first code line
        XCTAssertEqual(snap(fence + 2, forward: false), fence - 1)   // end of previous line
        XCTAssertEqual(snap(close, forward: true), close + 4)        // after the block
    }

    func testBackspaceAfterAHeadingPrefixRemovesThePrefix() {
        XCTAssertEqual(delete(1, caret: 2), .replace(NSRange(location: 0, length: 2)))
    }

    func testDeletingHiddenMarkupDeletesTheNearestVisibleCharacter() {
        let em = text.range(of: "*em*")
        XCTAssertEqual(delete(NSMaxRange(em) - 1, caret: NSMaxRange(em)),
                       .replace(NSRange(location: NSMaxRange(em) - 2, length: 1)))           // backspace: "m"
        XCTAssertEqual(delete(em.location, caret: em.location),
                       .replace(NSRange(location: em.location + 1, length: 1)))              // forward: "e"
    }

    func testBackspaceIntoACollapsedFenceDoesNothing() {
        let code = text.range(of: "code").location
        XCTAssertEqual(delete(code - 1, caret: code), .ignore)
    }

    func testVisibleDeletesAreUntouched() {
        XCTAssertEqual(delete(10, caret: 11), .allow)
    }

    func testToggleWrapWrapsAndUnwraps() {
        let wrap = EditRules.toggleWrap(NSRange(location: 9, length: 4), marker: "*", in: text)
        XCTAssertEqual(wrap?.patches, [.init(from: 9, to: 9, insert: "*"), .init(from: 13, to: 13, insert: "*")])
        XCTAssertEqual(wrap?.selection, NSRange(location: 10, length: 4))

        let em = text.range(of: "em")
        let unwrap = EditRules.toggleWrap(em, marker: "*", in: text)
        XCTAssertEqual(unwrap?.patches, [.init(from: em.location - 1, to: em.location, insert: ""),
                                         .init(from: NSMaxRange(em), to: NSMaxRange(em) + 1, insert: "")])
        XCTAssertEqual(unwrap?.selection, NSRange(location: em.location - 1, length: 2))

        XCTAssertNil(EditRules.toggleWrap(NSRange(location: 3, length: 0), marker: "*", in: text))
    }
}
