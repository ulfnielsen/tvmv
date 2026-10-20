import XCTest
@testable import TVMVCore

final class MarkdownLayoutParserTests: XCTestCase {
    /// The text each marker hides, in source order.
    private func hidden(_ text: String) -> [String] {
        let ns = text as NSString
        return MarkdownLayoutParser.parse(text).markers
            .sorted { $0.range.location < $1.range.location }
            .map { ns.substring(with: $0.range) }
    }

    /// The text of every style run matching `match`, in source order.
    private func styled(_ text: String, _ match: (MarkdownLayout.Style) -> Bool) -> [String] {
        let ns = text as NSString
        return MarkdownLayoutParser.parse(text).styles
            .filter { match($0.style) }
            .sorted { $0.range.location < $1.range.location }
            .map { ns.substring(with: $0.range) }
    }

    func testEmphasisStrongAndStrikethroughHideOnlyTheirDelimiters() {
        let text = "a **b** _c_ ~~d~~ ***e***\n"
        XCTAssertEqual(hidden(text), ["**", "**", "_", "_", "~~", "~~", "*", "**", "**", "*"])
        XCTAssertEqual(styled(text) { $0 == .strong }, ["b", "e"])
        XCTAssertEqual(styled(text) { $0 == .emphasis }, ["c", "**e**"])
        XCTAssertEqual(styled(text) { $0 == .strikethrough }, ["d"])
    }

    func testATXHeadingHidesPrefixAndClosingHashes() {
        let text = "## Title *x* ##\n"
        XCTAssertEqual(hidden(text), ["## ", "*", "*", " ##"])
        let layout = MarkdownLayoutParser.parse(text)
        XCTAssertEqual(layout.headings.map(\.level), [2])
        XCTAssertEqual(layout.headings.map(\.title), ["Title x"])
    }

    func testSetextUnderlineCollapses() {
        let text = "Title\n=====\n\nbody\n"
        let layout = MarkdownLayoutParser.parse(text)
        XCTAssertEqual(hidden(text), ["=====\n"])
        XCTAssertEqual(layout.markers.map(\.collapsesLine), [true])
        XCTAssertEqual(layout.headings.map(\.title), ["Title"])
    }

    func testFencedCodeCollapsesFencesAndKeepsTheBody() {
        let text = "```swift\nlet x = 1\n```\nafter\n"
        let ns = text as NSString
        let layout = MarkdownLayoutParser.parse(text)
        XCTAssertEqual(hidden(text), ["```swift\n", "```\n"])
        XCTAssertEqual(layout.markers.map(\.collapsesLine), [true, true])
        XCTAssertEqual(layout.codeBlocks.map { ns.substring(with: $0.body) }, ["let x = 1"])
        XCTAssertTrue(layout.styles.contains { $0.style == .codeBlock(language: "swift") })
    }

    func testUnclosedFenceHidesOnlyTheOpeningLine() {
        XCTAssertEqual(hidden("```\nstill open\n"), ["```\n"])
        // Final review: a last line that starts with backticks but carries an
        // info string can't close a fence; it is code and must stay visible.
        XCTAssertEqual(hidden("Intro\n\n```\nsome code\n```python\n"), ["```\n"])
    }

    func testCodeSpansHideTheirBacktickRuns() {
        XCTAssertEqual(hidden("a `c` b\n"), ["`", "`"])
        XCTAssertEqual(hidden("a `` x`y `` b\n"), ["``", "``"])
    }

    func testLinksAndAutolinks() {
        let text = "[text](http://a.b \"t\") [ref][r] <http://c.d> www.e.com\n\n[r]: http://r.s\n"
        XCTAssertEqual(hidden(text), ["[", "](http://a.b \"t\")", "[", "][r]", "<", ">"])
        let layout = MarkdownLayoutParser.parse(text)
        let ns = text as NSString
        let links = layout.styles.compactMap { run -> String? in
            switch run.style {
            case .link(let url), .autolink(let url): return "\(ns.substring(with: run.range)) -> \(url)"
            default: return nil
            }
        }
        XCTAssertEqual(links, ["text -> http://a.b", "ref -> http://r.s",
                               "http://c.d -> http://c.d", "www.e.com -> http://www.e.com"])
        XCTAssertEqual(layout.definitions.map(\.text), ["[r]: http://r.s"])
    }

    func testHardLineBreaksDoNotShiftLaterPositions() {
        // cmark's own inline positions are wrong after a hard break.
        let text = "a\\\nb *c* d  \ne **f**\n"
        XCTAssertEqual(hidden(text), ["*", "*", "**", "**"])
        XCTAssertEqual(styled(text) { $0 == .emphasis }, ["c"])
        XCTAssertEqual(styled(text) { $0 == .strong }, ["f"])
    }

    func testAstralAndCJKCharactersKeepOffsetsAligned() {
        let text = "é😀*x* 日本 **語**\n"
        XCTAssertEqual(hidden(text), ["*", "*", "**", "**"])
        XCTAssertEqual(styled(text) { $0 == .emphasis }, ["x"])
        XCTAssertEqual(styled(text) { $0 == .strong }, ["語"])
    }

    func testInlinePositionsInsideQuotesListsAndTables() {
        let text = "> quote *q*\n\n- item **one**\n- [ ] task `c`\n\n| A | *B* |\n|---|---|\n| 1 | `2` |\n"
        XCTAssertEqual(hidden(text), ["*", "*", "**", "**", "`", "`", "*", "*", "`", "`"])
    }

    func testSpellExemptions() {
        let text = "see `wrongg` and [l](http://wrongg.x)\n"
        let ns = text as NSString
        XCTAssertEqual(MarkdownLayoutParser.parse(text).spellExempt.map { ns.substring(with: $0) },
                       ["`wrongg`", "](http://wrongg.x)"])
    }

    func testEmptyAndMarkupFreeDocuments() {
        XCTAssertEqual(MarkdownLayoutParser.parse("").markers, [])
        XCTAssertEqual(MarkdownLayoutParser.parse("plain words").markers, [])
        XCTAssertEqual(MarkdownLayoutParser.parse("plain words").length, 11)
    }

    func testSoftLineBreaksInsideParagraphsAreRecorded() {
        // A paragraph wrapped across source lines reflows when rendered; only
        // its internal newlines are soft breaks — not hard breaks ("\\" or two
        // trailing spaces), not paragraph ends, not code, lists or quotes
        // (those keep their source layout until they render natively).
        let text = "one\ntwo\nthree\n\nhard\\\nnext  \nlast\n\n```\na\nb\n```\n\n- x\n  y\n\n> q\n> r\n"
        let ns = text as NSString
        let breaks = MarkdownLayoutParser.parse(text).softBreaks
        let lineAfter = breaks.map { ns.substring(with: ns.lineRange(for: NSRange(location: $0 + 1, length: 0))) }
        XCTAssertEqual(lineAfter, ["two\n", "three\n"])
        XCTAssertTrue(breaks.allSatisfy { ns.character(at: $0) == 10 })
    }

    func testAnImageAloneInItsParagraphIsABlockImage() {
        let text = "Intro.\n\n![A chart](img/chart.png \"Title\")\n\nText with ![inline](x.png) inside.\n\n![remote](https://e.x/p.png)\n"
        let ns = text as NSString
        let images = MarkdownLayoutParser.parse(text).blockImages
        XCTAssertEqual(images.map { ns.substring(with: $0.range) },
                       ["![A chart](img/chart.png \"Title\")", "![remote](https://e.x/p.png)"])
        XCTAssertEqual(images.map(\.url), ["img/chart.png", "https://e.x/p.png"])
        XCTAssertEqual(images.map(\.alt), ["A chart", "remote"])
    }

    func testTablesRecordTheirCellsRowsAndAlignment() {
        let text = "Intro.\n\n| Name | *Score* | Note |\n|:-----|------:|:---:|\n| Ada  | 10 | a \\| b |\n| Bob | 7 |  |\n\nAfter.\n"
        let ns = text as NSString
        let tables = MarkdownLayoutParser.parse(text).tables
        XCTAssertEqual(tables.count, 1)
        let table = tables[0]
        XCTAssertEqual(ns.substring(with: table.range), "| Name | *Score* | Note |\n|:-----|------:|:---:|\n| Ada  | 10 | a \\| b |\n| Bob | 7 |  |")
        XCTAssertEqual(table.alignments, [.left, .right, .center])
        // Cell ranges cover the content only — no pipes, no padding.
        XCTAssertEqual(table.rows.map { $0.map { ns.substring(with: $0) } },
                       [["Name", "*Score*", "Note"], ["Ada", "10", "a \\| b"], ["Bob", "7", ""]])
        // An empty cell is an empty range sitting between its pipes.
        let empty = table.rows[2][2]
        XCTAssertEqual(empty.length, 0)
        XCTAssertEqual(ns.character(at: empty.location - 1), 32)   // after the space following "|"
    }
}
