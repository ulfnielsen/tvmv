import XCTest
@testable import TVMVCore

/// Review markup folded into the native editor's layout.
final class ReviewLayoutTests: XCTestCase {
    private func hidden(_ text: String) -> [String] {
        let ns = text as NSString
        return MarkdownLayoutParser.parse(text).markers
            .sorted { $0.range.location < $1.range.location }
            .map { ns.substring(with: $0.range) }
    }

    private func styled(_ text: String, _ role: ReviewMarkup.Span.Role) -> [String] {
        let ns = text as NSString
        return MarkdownLayoutParser.parse(text).styles.compactMap { run in
            guard case .review(let r, _) = run.style, r == role else { return nil }
            return ns.substring(with: run.range)
        }
    }

    private let thread = "\n\n[^rv-a1b2]: @ulf 2026-10-14: Why?\n"

    func testAHighlightHidesItsDelimitersAndRef() {
        let text = "The {==cache==}[^rv-a1b2] is cold." + thread
        XCTAssertEqual(hidden(text), ["{==", "==}", "[^rv-a1b2]", "[^rv-a1b2]: @ulf 2026-10-14: Why?\n"])
        XCTAssertEqual(styled(text, .highlight), ["cache"])
    }

    func testAnAnchorRevealsAsOneUnit() {
        let text = "The {==cache==}[^rv-a1b2] is cold." + thread
        let layout = MarkdownLayoutParser.parse(text)
        let anchor = (text as NSString).range(of: "{==cache==}[^rv-a1b2]")
        XCTAssertEqual(Set(layout.markers.prefix(3).map(\.unit)), [anchor])
        XCTAssertTrue(layout.revealUnits.contains(anchor))
    }

    func testSuggestionsStyleEachSide() {
        let text = "a {++new++}[^rv-a1b2] b {--old--}[^rv-c3d4] c {~~was~>is~~}[^rv-e5f6]\n\n"
            + "[^rv-a1b2]: @ulf 2026-10-14 suggestion: x\n[^rv-c3d4]: @ulf 2026-10-14 suggestion: y\n"
            + "[^rv-e5f6]: @ulf 2026-10-14 suggestion: z\n"
        XCTAssertEqual(styled(text, .insertion), ["new"])
        XCTAssertEqual(styled(text, .deletion), ["old"])
        XCTAssertEqual(styled(text, .substitutionOld), ["was"])
        XCTAssertEqual(styled(text, .substitutionNew), ["is"])
        XCTAssertEqual(Array(hidden(text).prefix(9)),
                       ["{++", "++}", "[^rv-a1b2]", "{--", "--}", "[^rv-c3d4]", "{~~", "~>", "~~}"])
    }

    func testAPointCommentKeepsOneCharacterForItsMarker() {
        let text = "Needs a source.[^rv-a1b2]" + thread
        XCTAssertEqual(hidden(text).first, "^rv-a1b2]")
        XCTAssertEqual(styled(text, .pointMarker), ["["])
    }

    func testARefIsNotALinkAndThreadsAreNotProse() {
        let text = "The {==cache==}[^rv-a1b2] is cold." + thread
        let layout = MarkdownLayoutParser.parse(text)
        XCTAssertFalse(layout.styles.contains { if case .link = $0.style { return true } else { return false } })
        let definition = (text as NSString).range(of: "[^rv-a1b2]: @ulf 2026-10-14: Why?\n")
        XCTAssertTrue(layout.markers.contains { $0.range == definition && $0.collapsesLine && $0.unit == definition })
        XCTAssertTrue(layout.spellExempt.contains { $0.encloses(definition) })
        XCTAssertFalse(layout.styles.contains { NSIntersectionRange($0.range, definition).length > 0 })
    }

    func testAReplyLineCollapsesWithItsThread() {
        let text = "x[^rv-a1b2]\n\n[^rv-a1b2]: @ulf 2026-10-14: Why?\n    @claude 2026-10-14: *Because*.\n"
        let tail = (text as NSString).range(of: "[^rv-a1b2]: @ulf")
        let definition = NSRange(location: tail.location, length: (text as NSString).length - tail.location)
        XCTAssertEqual(MarkdownLayoutParser.parse(text).markers.filter(\.collapsesLine).map(\.range), [definition])
    }

    func testTheParsedReviewRidesAlong() {
        XCTAssertNil(MarkdownLayoutParser.parse("Plain *text*.\n").review)
        let review = MarkdownLayoutParser.parse("The {==cache==}[^rv-a1b2] is cold." + thread).review
        XCTAssertEqual(review?.threads.map(\.id), ["rv-a1b2"])
        XCTAssertEqual(review?.anchors.map(\.kind), [.highlight])
    }

    func testMarkupInCodeStaysCode() {
        let text = "`{==x==}[^rv-a1b2]`\n"
        XCTAssertEqual(hidden(text), ["`", "`"])
        XCTAssertEqual(styled(text, .highlight), [])
    }
}
