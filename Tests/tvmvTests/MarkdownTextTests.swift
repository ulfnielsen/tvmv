import XCTest
@testable import tvmv

final class MarkdownTextTests: XCTestCase {
    func testUTF8() {
        let (text, enc) = MarkdownText.decode(Data("héllo".utf8))
        XCTAssertEqual(text, "héllo")
        XCTAssertEqual(enc, .utf8)
    }
    func testLatin1Fallback() {
        // 0xFF is invalid UTF-8 but valid Latin-1 (ÿ).
        let (text, enc) = MarkdownText.decode(Data([0xFF]))
        XCTAssertEqual(enc, .isoLatin1)
        XCTAssertEqual(text, "ÿ")
    }
}
