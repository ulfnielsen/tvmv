import XCTest
@testable import TVMVCore

final class SourceMapTests: XCTestCase {
    func testASCIIPositions() {
        let map = SourceMap("ab\ncd\n")
        XCTAssertEqual(map.offset(line: 1, column: 1), 0)
        XCTAssertEqual(map.offset(line: 2, column: 2), 4)
        XCTAssertEqual(map.range(startLine: 2, startColumn: 1, endLine: 2, endColumn: 2),
                       NSRange(location: 3, length: 2))
    }

    func testColumnsCountBytesButOffsetsCountUTF16() {
        // "é" is 2 UTF-8 bytes and 1 UTF-16 unit; "😀" is 4 bytes and 2 units.
        let map = SourceMap("é😀x\n")
        XCTAssertEqual(map.offset(line: 1, column: 1), 0)   // é
        XCTAssertEqual(map.offset(line: 1, column: 3), 1)   // 😀 starts at byte 3
        XCTAssertEqual(map.offset(line: 1, column: 7), 3)   // x
        XCTAssertEqual(map.range(startLine: 1, startColumn: 3, endLine: 1, endColumn: 6),
                       NSRange(location: 1, length: 2))
        // A position naming a continuation byte snaps to its character.
        XCTAssertEqual(map.offset(line: 1, column: 4), 1)
        XCTAssertEqual(map.endOffset(line: 1, column: 4), 3)
    }

    func testColumnZeroMeansEndOfPreviousLine() {
        XCTAssertEqual(SourceMap("ab\ncd\n").endOffset(line: 2, column: 0), 3)
    }

    func testMissingPositionsAreNil() {
        let map = SourceMap("ab\n")
        XCTAssertNil(map.offset(line: 0, column: 0))
        XCTAssertNil(map.offset(line: 9, column: 1))
        XCTAssertNil(map.range(startLine: 0, startColumn: 0, endLine: 0, endColumn: 0))
    }
}
