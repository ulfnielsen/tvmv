import XCTest
@testable import tvmv

final class LineIndexTests: XCTestCase {
    let text = "line one\nline two\n\nline four"   // lines 1,2,3(empty),4

    func testLineAtOffset() {
        XCTAssertEqual(LineIndex.line(at: 0, in: text), 1)
        XCTAssertEqual(LineIndex.line(at: 8, in: text), 1)    // before the \n
        XCTAssertEqual(LineIndex.line(at: 9, in: text), 2)    // start of "line two"
        XCTAssertEqual(LineIndex.line(at: 18, in: text), 3)   // the empty line
        XCTAssertEqual(LineIndex.line(at: 19, in: text), 4)
        XCTAssertEqual(LineIndex.line(at: 999, in: text), 4)  // clamped
        XCTAssertEqual(LineIndex.line(at: 0, in: ""), 1)
    }
    func testOffsetOfLine() {
        XCTAssertEqual(LineIndex.offset(ofLine: 1, in: text), 0)
        XCTAssertEqual(LineIndex.offset(ofLine: 2, in: text), 9)
        XCTAssertEqual(LineIndex.offset(ofLine: 3, in: text), 18)
        XCTAssertEqual(LineIndex.offset(ofLine: 4, in: text), 19)
        XCTAssertEqual(LineIndex.offset(ofLine: 99, in: text), 19)  // clamped to last line
        XCTAssertEqual(LineIndex.offset(ofLine: 1, in: ""), 0)
    }
    func testUTF16Offsets() {
        // "🌍" is 2 UTF-16 units; NSTextView ranges count UTF-16, so we must too.
        let t = "a🌍\nb"
        XCTAssertEqual(LineIndex.line(at: 3, in: t), 1)   // offset 3 = the \n
        XCTAssertEqual(LineIndex.offset(ofLine: 2, in: t), 4)
    }
}
