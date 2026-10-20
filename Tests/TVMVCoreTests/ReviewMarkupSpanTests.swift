import XCTest
@testable import TVMVCore

/// `ReviewMarkup.spans`: what `MarkdownLayout` needs to hide, style, exempt
/// from spelling, and collapse.
final class ReviewMarkupSpanTests: XCTestCase {

    private func described(_ text: String) -> [String] {
        let units = Array(text.utf16)
        return ReviewMarkup.spans(ReviewMarkup.parse(text)).map {
            "\($0.role) \($0.id) \(String(decoding: units[$0.range], as: UTF16.self).debugDescription)"
        }
    }

    func testEveryAnchorKindAndDefinition() {
        let text = "{==a==}[^rv-aaaa] {++b++}[^rv-bbbb] {--c--}[^rv-bbbb] {~~d~>e~~}[^rv-bbbb] f[^rv-aaaa]\n\n"
            + "[^rv-aaaa]: @x 2026-10-14: 1\n    @y 2026-10-14: 2\n[^rv-bbbb]: @x 2026-10-14 suggestion: 3\n"
        XCTAssertEqual(described(text), [
            "delimiter rv-aaaa \"{==\"", "highlight rv-aaaa \"a\"", "delimiter rv-aaaa \"==}\"",
            "ref rv-aaaa \"[^rv-aaaa]\"",
            "delimiter rv-bbbb \"{++\"", "insertion rv-bbbb \"b\"", "delimiter rv-bbbb \"++}\"",
            "ref rv-bbbb \"[^rv-bbbb]\"",
            "delimiter rv-bbbb \"{--\"", "deletion rv-bbbb \"c\"", "delimiter rv-bbbb \"--}\"",
            "ref rv-bbbb \"[^rv-bbbb]\"",
            "delimiter rv-bbbb \"{~~\"", "substitutionOld rv-bbbb \"d\"", "delimiter rv-bbbb \"~>\"",
            "substitutionNew rv-bbbb \"e\"", "delimiter rv-bbbb \"~~}\"", "ref rv-bbbb \"[^rv-bbbb]\"",
            "pointMarker rv-aaaa \"[^rv-aaaa]\"",
            "definition rv-aaaa \"[^rv-aaaa]: @x 2026-10-14: 1\\n    @y 2026-10-14: 2\\n\"",
            "definition rv-bbbb \"[^rv-bbbb]: @x 2026-10-14 suggestion: 3\\n\"",
        ])
    }

    func testSpellingExemptions() {
        let text = "{==a==}[^rv-aaaa] b[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-14: 1\n"
        let spans = ReviewMarkup.spans(ReviewMarkup.parse(text))
        let exempt = Dictionary(spans.map { ("\($0.role)", $0.isSpellingExempt) },
                                uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(exempt, ["delimiter": true, "ref": true, "highlight": false,
                                "pointMarker": true, "definition": true])
        XCTAssertEqual(spans.filter(\.isHidden).map { "\($0.role)" }, ["delimiter", "delimiter", "ref"])
    }

    func testSpansAreSortedAndDisjoint() {
        let spans = ReviewMarkup.spans(ReviewMarkup.parse(ReviewMarkupParseTests.specExample))
        XCTAssertFalse(spans.isEmpty)
        for (a, b) in zip(spans, spans.dropFirst()) {
            XCTAssertLessThanOrEqual(a.range.upperBound, b.range.lowerBound, "\(a) then \(b)")
        }
    }
}
