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
    func testEncodeDecodeRoundTripUTF8() {
        let text = "# héllo → 🌍\n"
        let data = MarkdownText.encode(text, encoding: .utf8)
        let decoded = MarkdownText.decode(data)
        XCTAssertEqual(decoded.text, text)
        XCTAssertEqual(decoded.encoding, .utf8)
    }
    func testEncodeDecodeRoundTripUTF16() {
        let text = "# héllo\n"
        let data = MarkdownText.encode(text, encoding: .utf16)
        let decoded = MarkdownText.decode(data)
        XCTAssertEqual(decoded.text, text)
        XCTAssertEqual(decoded.encoding, .utf16)   // BOM must be present
    }
    func testEncodeDecodeRoundTripLatin1() {
        let text = "café\n"   // representable in Latin-1... but decode sees valid UTF-8?
        let data = MarkdownText.encode(text, encoding: .isoLatin1)
        // Latin-1 "café" bytes (é = 0xE9) are NOT valid UTF-8, so decode
        // falls through to Latin-1 — the round-trip the feature needs.
        let decoded = MarkdownText.decode(data)
        XCTAssertEqual(decoded.text, text)
        XCTAssertEqual(decoded.encoding, .isoLatin1)
    }
    func testEncodeLatin1FallsBackToUTF8WhenUnrepresentable() {
        let text = "café 🌍\n"   // emoji is not Latin-1 representable
        let data = MarkdownText.encode(text, encoding: .isoLatin1)
        XCTAssertEqual(String(data: data, encoding: .utf8), text)
    }
}
