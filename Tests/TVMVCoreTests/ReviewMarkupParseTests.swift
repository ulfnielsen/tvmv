import XCTest
@testable import TVMVCore

/// `ReviewMarkup.parse`: anchors, threads and problems, in UTF-16 ranges.
final class ReviewMarkupParseTests: XCTestCase {

    /// The spec's own example, verbatim.
    static let specExample = """
        The {==cache is invalidated on every save==}[^rv-k3f9] and the index is
        {~~rebuilt lazily~>rebuilt eagerly on open~~}[^rv-p2x7] from disk.
        {++Autosave writes are exempt.++}[^rv-p2x7] A point comment.[^rv-z9y8]

        [^rv-k3f9]: @ulf 2026-10-14: True for autosave too?
            @claude 2026-10-14: No, see the added sentence.
        [^rv-p2x7]: @claude 2026-10-14 suggestion: Eager rebuild avoids the first-scroll stall.
        [^rv-z9y8]: @ulf 2026-10-14: Needs a source.

        """

    /// The slice of `text` covered by a UTF-16 range.
    private func slice(_ text: String, _ range: Range<Int>) -> String {
        let units = Array(text.utf16)[range]
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: Anchors

    func testSpecExampleParsesCleanly() {
        let text = Self.specExample
        let review = ReviewMarkup.parse(text)

        XCTAssertEqual(review.problems, [])
        XCTAssertEqual(review.anchors.map(\.kind),
                       [.highlight, .substitution, .insertion, .point])
        XCTAssertEqual(review.anchors.map(\.id),
                       ["rv-k3f9", "rv-p2x7", "rv-p2x7", "rv-z9y8"])

        let highlight = review.anchors[0]
        XCTAssertEqual(slice(text, highlight.range),
                       "{==cache is invalidated on every save==}[^rv-k3f9]")
        XCTAssertEqual(slice(text, highlight.inner), "cache is invalidated on every save")
        XCTAssertEqual(slice(text, highlight.ref), "[^rv-k3f9]")
        XCTAssertNil(highlight.old)
        XCTAssertNil(highlight.new)

        let substitution = review.anchors[1]
        XCTAssertEqual(slice(text, substitution.old!), "rebuilt lazily")
        XCTAssertEqual(slice(text, substitution.new!), "rebuilt eagerly on open")
        XCTAssertEqual(slice(text, substitution.inner), "rebuilt lazily~>rebuilt eagerly on open")

        let insertion = review.anchors[2]
        XCTAssertEqual(slice(text, insertion.inner), "Autosave writes are exempt.")

        let point = review.anchors[3]
        XCTAssertEqual(slice(text, point.range), "[^rv-z9y8]")
        XCTAssertEqual(point.ref, point.range)
        XCTAssertTrue(point.inner.isEmpty)
    }

    func testDeletionAnchor() {
        let text = "Keep {--this part--}[^rv-ab12] out.\n\n[^rv-ab12]: @ulf 2026-10-14 suggestion: Cut.\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.problems, [])
        XCTAssertEqual(review.anchors.count, 1)
        XCTAssertEqual(review.anchors[0].kind, .deletion)
        XCTAssertEqual(slice(text, review.anchors[0].inner), "this part")
    }

    func testMarkupWithoutRefIsNotAnAnchor() {
        // "An anchor without one is shown as markup, with no thread or actions."
        let review = ReviewMarkup.parse("Plain {==highlight==} and {++insert++} here.\n")
        XCTAssertEqual(review.anchors, [])
        XCTAssertEqual(review.problems, [])
    }

    func testNonReviewFootnotesAreLeftAlone() {
        let text = "A {==note==}[^1] and[^note].\n\n[^1]: Ordinary footnote.\n[^note]: Another.\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.anchors, [])
        XCTAssertEqual(review.threads, [])
        XCTAssertEqual(review.problems, [])
    }

    func testMarkupInsideFencedCodeIsNotParsed() {
        let text = """
            ```md
            {==not an anchor==}[^rv-aaaa]
            ```
            [^rv-bbbb]

            [^rv-bbbb]: @ulf 2026-10-14: On the code block.

            """
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.anchors.map(\.id), ["rv-bbbb"])
        XCTAssertEqual(review.anchors[0].kind, .point)
        XCTAssertEqual(review.problems, [])
    }

    func testTildeFenceAndNestedFenceInList() {
        let text = """
            ~~~
            {==a==}[^rv-aaaa]
            ~~~

            - item
              ```
              {==b==}[^rv-bbbb]
              ```

            """
        XCTAssertEqual(ReviewMarkup.parse(text).anchors, [])
    }

    func testMarkupInsideMathBlockIsNotParsed() {
        let text = "$$\n{==x==}[^rv-aaaa]\n$$\n\nAfter.\n"
        XCTAssertEqual(ReviewMarkup.parse(text).anchors, [])
    }

    func testMarkupInsideInlineCodeIsNotParsed() {
        let text = "Write `{==x==}[^rv-aaaa]` to highlight.\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.anchors, [])
        XCTAssertEqual(review.problems, [])
    }

    func testCodeSpanInsideAnchorDoesNotEndIt() {
        let text = "{==use `==}` here==}[^rv-aaaa]\n\n[^rv-aaaa]: @ulf 2026-10-14: ok\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.problems, [])
        XCTAssertEqual(slice(text, review.anchors[0].inner), "use `==}` here")
    }

    func testAnchorMaySpanSoftLineBreak() {
        let text = "{==first line\nsecond line==}[^rv-aaaa]\n\n[^rv-aaaa]: @ulf 2026-10-14: ok\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.problems, [])
        XCTAssertEqual(slice(text, review.anchors[0].inner), "first line\nsecond line")
    }

    func testAnchorInTableCell() {
        let text = "| a | b |\n|---|---|\n| {==one==}[^rv-aaaa] | two |\n\n[^rv-aaaa]: @ulf 2026-10-14: ok\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.problems, [])
        XCTAssertEqual(slice(text, review.anchors[0].inner), "one")
    }

    func testRangesAreUTF16() {
        let text = "👍 {==café 🎉==}[^rv-aaaa]\n\n[^rv-aaaa]: @ulf 2026-10-14: ok 🙂\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.anchors[0].range.lowerBound, 3)   // 👍 is 2 units, then a space
        XCTAssertEqual(slice(text, review.anchors[0].inner), "café 🎉")
        XCTAssertEqual(review.threads[0].entries[0].body, "ok 🙂")
    }

    // MARK: Threads

    func testThreadsCarryEntriesAndRanges() {
        let text = Self.specExample
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.threads.map(\.id), ["rv-k3f9", "rv-p2x7", "rv-z9y8"])

        let first = review.threads[0]
        XCTAssertEqual(slice(text, first.range), """
            [^rv-k3f9]: @ulf 2026-10-14: True for autosave too?
                @claude 2026-10-14: No, see the added sentence.

            """)
        XCTAssertEqual(first.entries, [
            ReviewMarkup.Entry(author: "ulf", date: "2026-10-14", kind: .comment,
                               body: "True for autosave too?",
                               range: first.entries[0].range),
            ReviewMarkup.Entry(author: "claude", date: "2026-10-14", kind: .comment,
                               body: "No, see the added sentence.",
                               range: first.entries[1].range),
        ])
        XCTAssertEqual(slice(text, first.entries[1].range),
                       "    @claude 2026-10-14: No, see the added sentence.")

        XCTAssertEqual(review.threads[1].entries[0].kind, .suggestion)
        XCTAssertEqual(review.threads[1].entries[0].body,
                       "Eager rebuild avoids the first-scroll stall.")
    }

    func testMultiLineEntryBodyAndEmptySuggestionBody() {
        let text = """
            x[^rv-aaaa] {++y++}[^rv-bbbb]

            [^rv-aaaa]: @ulf 2026-10-14: First line
                continues here.
                @bob 2026-10-15: Reply.
            [^rv-bbbb]: @ulf 2026-10-14 suggestion:

            """
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.problems, [])
        XCTAssertEqual(review.threads[0].entries.map(\.body),
                       ["First line\ncontinues here.", "Reply."])
        XCTAssertEqual(review.threads[0].entries.map(\.author), ["ulf", "bob"])
        XCTAssertEqual(review.threads[1].entries.map(\.body), [""])
        XCTAssertEqual(review.threads[1].entries.map(\.kind), [.suggestion])
    }

    func testUnindentedEntryLineDirectlyAfterIsAReply() {
        // GFM treats it as a lazy continuation of the footnote, so an agent
        // that forgets the indent still lands in the thread.
        let text = "x[^rv-aaaa]\n\n[^rv-aaaa]: @ulf 2026-10-14: Q?\n@claude 2026-10-14: A.\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.threads[0].entries.map(\.author), ["ulf", "claude"])
        XCTAssertEqual(review.threads[0].range.upperBound, text.utf16.count)
    }

    func testThreadWithoutTrailingNewline() {
        let text = "x[^rv-aaaa]\n\n[^rv-aaaa]: @ulf 2026-10-14: Q?"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.problems, [])
        XCTAssertEqual(review.threads[0].range.upperBound, text.utf16.count)
    }

    func testDefinitionLabelIsNotAPointAnchor() {
        let review = ReviewMarkup.parse("[^rv-aaaa]: @ulf 2026-10-14: orphan\n")
        XCTAssertEqual(review.anchors, [])
        XCTAssertEqual(review.threads.count, 1)
    }

    func testMarkupInsideThreadBodyIsNotParsed() {
        let text = "x[^rv-aaaa]\n\n[^rv-aaaa]: @ulf 2026-10-14: Use {==this==}[^rv-zzzz] and [^rv-yyyy].\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.anchors.map(\.id), ["rv-aaaa"])
        XCTAssertEqual(review.problems, [])
    }

    // MARK: Problems

    func testOrphanThread() {
        let text = "No anchors.\n\n[^rv-aaaa]: @ulf 2026-10-14: Lost.\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.problems, [.orphanThread(id: "rv-aaaa", range: review.threads[0].range)])
    }

    func testDanglingAnchor() {
        let text = "See {==this==}[^rv-aaaa].\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.problems, [.danglingAnchor(id: "rv-aaaa", range: review.anchors[0].range)])
    }

    func testUnclosedOpenerIsUnbalanced() {
        let text = "Start {==never closed.\n"
        XCTAssertEqual(ReviewMarkup.parse(text).problems, [.unbalanced(range: 6..<9)])
    }

    func testAnchorCannotSpanABlankLine() {
        let text = "{==one\n\ntwo==}[^rv-aaaa]\n\n[^rv-aaaa]: @ulf 2026-10-14: x\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.anchors.filter { $0.kind != .point }, [])
        XCTAssertTrue(review.problems.contains(.unbalanced(range: 0..<3)), "\(review.problems)")
        XCTAssertTrue(review.problems.contains(.unbalanced(range: 11..<14)), "\(review.problems)")
    }

    func testSubstitutionWithoutSeparatorIsUnbalanced() {
        let text = "{~~old new~~}[^rv-aaaa]\n"
        XCTAssertTrue(ReviewMarkup.parse(text).problems.contains(.unbalanced(range: 0..<3)))
    }

    func testStrayCloserIsUnbalanced() {
        XCTAssertEqual(ReviewMarkup.parse("oops++} here\n").problems, [.unbalanced(range: 4..<7)])
    }

    func testMixedKindsUnderOneID() {
        let text = "{==a==}[^rv-aaaa] {++b++}[^rv-aaaa]\n\n[^rv-aaaa]: @ulf 2026-10-14: x\n"
        XCTAssertEqual(ReviewMarkup.parse(text).problems, [.mixedKinds(id: "rv-aaaa")])
    }

    func testHighlightAndPointShareCommentKind() {
        let text = "{==a==}[^rv-aaaa] b[^rv-aaaa]\n\n[^rv-aaaa]: @ulf 2026-10-14: x\n"
        XCTAssertEqual(ReviewMarkup.parse(text).problems, [])
    }

    func testDuplicateThread() {
        let text = "a[^rv-aaaa]\n\n[^rv-aaaa]: @ulf 2026-10-14: one\n[^rv-aaaa]: @ulf 2026-10-14: two\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.problems, [.duplicateThread(id: "rv-aaaa", range: review.threads[1].range)])
    }

    func testMalformedEntryIsKeptAndReported() {
        let text = "a[^rv-aaaa]\n\n[^rv-aaaa]: just some words\n"
        let review = ReviewMarkup.parse(text)
        XCTAssertEqual(review.threads[0].entries.map(\.body), ["just some words"])
        XCTAssertEqual(review.threads[0].entries.map(\.author), [""])
        XCTAssertEqual(review.problems,
                       [.malformedEntry(id: "rv-aaaa", range: review.threads[0].entries[0].range)])
    }

    // MARK: Robustness

    /// Parsing never throws or traps, and every reported range lies inside
    /// the text, whatever a hand edit left behind.
    func testRandomFragmentsNeverTrapAndStayInBounds() {
        let fragments = ["{==", "==}", "{++", "++}", "{--", "--}", "{~~", "~>", "~~}",
                         "[^rv-aaaa]", "[^rv-bb1]", "[^rv-", "]", ":", " ", "\n", "\n\n",
                         "[^rv-aaaa]: @ulf 2026-10-14: c", "    @bob 2026-10-14: r",
                         "`", "```", "$$", "x", "é", "👍", "@", "\t"]
        var rng = SplitMix64(seed: 42)
        for _ in 0..<2_000 {
            let count = Int(rng.next() % 24)
            let text = (0..<count).map { _ in fragments[Int(rng.next() % UInt64(fragments.count))] }
                .joined()
            let length = text.utf16.count
            let review = ReviewMarkup.parse(text)
            for anchor in review.anchors {
                for range in [anchor.range, anchor.inner, anchor.ref]
                    + [anchor.old, anchor.new].compactMap({ $0 }) {
                    XCTAssertTrue(range.lowerBound >= 0 && range.upperBound <= length,
                                  "anchor out of bounds in \(text.debugDescription)")
                }
            }
            for thread in review.threads {
                XCTAssertTrue(thread.range.upperBound <= length,
                              "thread out of bounds in \(text.debugDescription)")
            }
        }
    }
}

/// Small deterministic PRNG so property tests replay identically.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
