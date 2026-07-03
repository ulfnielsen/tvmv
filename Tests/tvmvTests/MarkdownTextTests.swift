import XCTest
@testable import tvmv

final class MarkdownTextTests: XCTestCase {
    func testUTF8() {
        let d = MarkdownText.decode(Data("héllo".utf8))
        XCTAssertEqual(d.text, "héllo")
        XCTAssertEqual(d.encoding, .utf8)
    }
    func testLatin1Fallback() {
        // 0xFF is invalid UTF-8 but valid Latin-1 (ÿ).
        let d = MarkdownText.decode(Data([0xFF]))
        XCTAssertEqual(d.encoding, .isoLatin1)
        XCTAssertEqual(d.text, "ÿ")
    }
    // Line endings: the model always holds LF (CodeMirror normalizes its
    // document the same way, so untouched files never look dirty); the
    // original style is recorded and restored on encode.
    func testDecodeNormalizesCRLFAndRecordsIt() {
        let d = MarkdownText.decode(Data("a\r\nb\r\n".utf8))
        XCTAssertEqual(d.text, "a\nb\n")
        XCTAssertEqual(d.lineEnding, .crlf)
    }
    func testDecodeNormalizesLoneCR() {
        let d = MarkdownText.decode(Data("a\rb".utf8))
        XCTAssertEqual(d.text, "a\nb")
        XCTAssertEqual(d.lineEnding, .cr)
    }
    func testDecodeLFIsDefault() {
        XCTAssertEqual(MarkdownText.decode(Data("a\nb".utf8)).lineEnding, .lf)
    }
    func testEncodeRestoresCRLF() {
        let data = MarkdownText.encode("a\nb\n", encoding: .utf8, lineEnding: .crlf)
        XCTAssertEqual(String(data: data, encoding: .utf8), "a\r\nb\r\n")
    }
    func testCRLFByteRoundTrip() {
        let original = Data("# hé\r\nline two\r\n".utf8)
        let d = MarkdownText.decode(original)
        let out = MarkdownText.encode(d.text, encoding: d.encoding, lineEnding: d.lineEnding)
        XCTAssertEqual(out, original)
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
