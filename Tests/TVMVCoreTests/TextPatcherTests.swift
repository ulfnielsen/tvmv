import XCTest
@testable import TVMVCore

final class TextPatcherTests: XCTestCase {
    private func p(_ from: Int, _ to: Int, _ insert: String) -> TextPatcher.Patch {
        TextPatcher.Patch(from: from, to: to, insert: insert)
    }

    func testInsert() {
        XCTAssertEqual(TextPatcher.apply([p(5, 5, " brave")], to: "hello world"),
                       "hello brave world")
    }

    func testDelete() {
        XCTAssertEqual(TextPatcher.apply([p(5, 11, "")], to: "hello world"), "hello")
    }

    func testReplace() {
        XCTAssertEqual(TextPatcher.apply([p(6, 11, "there")], to: "hello world"),
                       "hello there")
    }

    func testMultiplePatchesApplyInBaseCoordinates() {
        // Both ranges refer to the ORIGINAL text; a naive forward application
        // without offset care would corrupt the second.
        XCTAssertEqual(
            TextPatcher.apply([p(0, 1, "J"), p(6, 11, "moon")], to: "hello world"),
            "Jello moon")
    }

    func testEmptyPatchListIsIdentity() {
        XCTAssertEqual(TextPatcher.apply([], to: "abc"), "abc")
    }

    func testUTF16OffsetsWithSurrogatePairs() {
        // "👍" is two UTF-16 units; CodeMirror counts in UTF-16.
        let base = "a👍b"          // offsets: a=0, 👍=1..3, b=3
        XCTAssertEqual(TextPatcher.apply([p(3, 4, "c")], to: base), "a👍c")
        XCTAssertEqual(TextPatcher.apply([p(1, 3, "x")], to: base), "axb")
    }

    func testOutOfBoundsReturnsNil() {
        XCTAssertNil(TextPatcher.apply([p(0, 99, "")], to: "short"))
        XCTAssertNil(TextPatcher.apply([p(-1, 2, "")], to: "short"))
    }

    func testOverlappingPatchesReturnNil() {
        XCTAssertNil(TextPatcher.apply([p(0, 5, "x"), p(3, 8, "y")], to: "0123456789"))
    }

    func testUnorderedPatchesReturnNil() {
        XCTAssertNil(TextPatcher.apply([p(6, 8, "x"), p(0, 2, "y")], to: "0123456789"))
    }

    func testInvertedRangeReturnsNil() {
        XCTAssertNil(TextPatcher.apply([p(5, 2, "x")], to: "0123456789"))
    }

    func testExpectedLengthMismatchReturnsNil() {
        XCTAssertNil(TextPatcher.apply([p(0, 0, "xy")], to: "abc", expectedUTF16Length: 4))
        XCTAssertEqual(TextPatcher.apply([p(0, 0, "xy")], to: "abc", expectedUTF16Length: 5),
                       "xyabc")
    }
}
