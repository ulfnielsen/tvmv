import XCTest
@testable import TVMVCore

/// Review markup in `renderHTML`: anchors become `<mark>`, `<ins>` and
/// `<del>` carrying `data-rv`, and `rv-` threads render as GFM footnotes
/// (print, QuickLook and the iOS/Linux reader all go through here).
final class ReviewMarkupRenderTests: XCTestCase {

    private func ref(_ id: String, _ n: Int) -> String {
        "<sup class=\"footnote-ref\"><a href=\"#fn-\(id)\" id=\"fnref-\(id)\" data-footnote-ref>\(n)</a></sup>"
    }

    func testFootnotesAreEnabled() {
        let html = renderHTML("Text[^1].\n\n[^1]: Note.\n")
        XCTAssertTrue(html.contains(ref("1", 1)), html)
        XCTAssertTrue(html.contains("<section class=\"footnotes\" data-footnotes>"), html)
    }

    /// Snapshot of the spec's example, every anchor kind plus threads.
    func testSpecExampleSnapshot() {
        let html = renderHTML(ReviewMarkupParseTests.specExample)
        XCTAssertEqual(html, """
            <p>The <mark data-rv="rv-k3f9">cache is invalidated on every save</mark>\(ref("rv-k3f9", 1)) and the index is
            <del data-rv="rv-p2x7">rebuilt lazily</del><ins data-rv="rv-p2x7">rebuilt eagerly on open</ins>\(ref("rv-p2x7", 2)) from disk.
            <ins data-rv="rv-p2x7">Autosave writes are exempt.</ins><sup class="footnote-ref"><a href="#fn-rv-p2x7" id="fnref-rv-p2x7-2" data-footnote-ref>2</a></sup> A point comment.\(ref("rv-z9y8", 3))</p>
            <section class="footnotes" data-footnotes>
            <ol>
            <li id="fn-rv-k3f9">
            <p>@ulf 2026-10-14: True for autosave too?<br />
            @claude 2026-10-14: No, see the added sentence. <a href="#fnref-rv-k3f9" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="1" aria-label="Back to reference 1">↩</a></p>
            </li>
            <li id="fn-rv-p2x7">
            <p>@claude 2026-10-14 suggestion: Eager rebuild avoids the first-scroll stall. <a href="#fnref-rv-p2x7" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="2" aria-label="Back to reference 2">↩</a> <a href="#fnref-rv-p2x7-2" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="2-2" aria-label="Back to reference 2-2">↩<sup class="footnote-ref">2</sup></a></p>
            </li>
            <li id="fn-rv-z9y8">
            <p>@ulf 2026-10-14: Needs a source. <a href="#fnref-rv-z9y8" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="3" aria-label="Back to reference 3">↩</a></p>
            </li>
            </ol>
            </section>

            """)
    }

    func testDeletion() {
        let html = renderHTML("Keep {--this--}[^rv-aaaa].\n\n[^rv-aaaa]: @x 2026-10-14 suggestion: y\n")
        XCTAssertTrue(html.contains("<p>Keep <del data-rv=\"rv-aaaa\">this</del>\(ref("rv-aaaa", 1)).</p>"), html)
    }

    func testInlineFormattingInsideAnchors() {
        let html = renderHTML("{==*very* `x`==}[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-14: y\n")
        XCTAssertTrue(html.contains("<mark data-rv=\"rv-aaaa\"><em>very</em> <code>x</code></mark>"), html)
    }

    /// The substitution's `~~` must not be read as GFM strikethrough.
    func testSubstitutionIsNotStrikethrough() {
        let html = renderHTML("{~~a~>b~~}[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-14 suggestion: y\n")
        XCTAssertTrue(html.contains("<del data-rv=\"rv-aaaa\">a</del><ins data-rv=\"rv-aaaa\">b</ins>"), html)
        XCTAssertFalse(html.contains("~"), html)
    }

    func testDanglingAnchorStillMarksItsText() {
        let html = renderHTML("See {==this==}[^rv-aaaa].\n")
        XCTAssertTrue(html.contains("<p>See <mark data-rv=\"rv-aaaa\">this</mark>[^rv-aaaa].</p>"), html)
    }

    func testBareMarkupAndCodeAreLeftAlone() {
        let markdown = "Plain {==x==} here and `{==y==}[^rv-aaaa]` there.\n\n```\n{++z++}[^rv-aaaa]\n```\n"
        XCTAssertEqual(renderHTML(markdown),
                       "<p>Plain {==x==} here and <code>{==y==}[^rv-aaaa]</code> there.</p>\n"
                       + "<pre><code>{++z++}[^rv-aaaa]\n</code></pre>\n")
    }

    /// Markup inside an attribute (an image's alt text) cannot become tags;
    /// it falls back to its literal delimiters.
    func testMarkupInsideAttributeStaysText() {
        let html = renderHTML("![a {==b==}[^rv-aaaa]](i.png)\n\n[^rv-aaaa]: @x 2026-10-14: y\n")
        XCTAssertTrue(html.contains("alt=\"a {==b==}\""), html)
        XCTAssertFalse(html.contains("<mark"), html)
        XCTAssertFalse(html.unicodeScalars.contains { (0xE000...0xE0FF).contains($0.value) || $0.value == 0x80 }, html)
    }

    /// A document that already contains a sentinel character renders as
    /// plain Markdown rather than having it misread as review markup.
    func testSourceContainingSentinelsSkipsReviewRendering() {
        let html = renderHTML("\u{E001} {==x==}[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-14: y\n")
        XCTAssertTrue(html.contains("\u{E001} {==x==}"), html)
        XCTAssertFalse(html.contains("<mark"), html)
    }

    /// The pre-pass keeps every line's byte length, so `data-sourcepos`
    /// columns match the file as written.
    func testSourcePositionsAreUnchanged() {
        let markdown = "A {==b==}[^rv-aaaa] {~~c~>d~~}[^rv-bbbb] {++e++}[^rv-aaaa] {--f--}[^rv-aaaa]\n\nnext\n\n"
            + "[^rv-aaaa]: @x 2026-10-14: y\n[^rv-bbbb]: @x 2026-10-14 suggestion: z\n"
        let html = renderHTML(markdown, sourcePos: true)
        let firstLine = "A {==b==}[^rv-aaaa] {~~c~>d~~}[^rv-bbbb] {++e++}[^rv-aaaa] {--f--}[^rv-aaaa]"
        XCTAssertTrue(html.contains("<p data-sourcepos=\"1:1-1:\(firstLine.utf8.count)\">"), html)
        XCTAssertTrue(html.contains("<p data-sourcepos=\"3:1-3:4\">next</p>"), html)
    }

    /// Without review markup the pass is skipped entirely: output is plain
    /// cmark-gfm with footnotes on.
    func testDocumentsWithoutReviewMarkupAreUntouched() {
        let markdown = "# T\n\n{==not review==} and ~~strike~~\n"
        XCTAssertEqual(renderHTML(markdown),
                       "<h1>T</h1>\n<p>{==not review==} and <del>strike</del></p>\n")
    }
}
