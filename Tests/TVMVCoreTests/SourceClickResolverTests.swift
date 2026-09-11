import XCTest
@testable import TVMVCore

/// The preview reports "you clicked the Nth occurrence of WORD inside the block
/// that starts at line L". These tests pin how that is turned back into a caret
/// position in the Markdown source.
final class SourceClickResolverTests: XCTestCase {

    private let doc = """
    # Title

    The quick brown fox jumps over the lazy dog.
    The dog barks and the fox runs.

    | Animal | Sound |
    | ------ | ----- |
    | dog    | woof  |
    | fox    | yip   |
    """

    func testResolvesFirstOccurrenceInABlock() {
        let hit = SourceClickResolver.resolve(
            in: doc, word: "fox", ordinal: 1, startLine: 3, endLine: 4)
        XCTAssertEqual(hit, SourceClickResolver.Target(line: 3, column: 17))
    }

    func testResolvesLaterOccurrenceAcrossLinesOfTheSameBlock() {
        let hit = SourceClickResolver.resolve(
            in: doc, word: "fox", ordinal: 2, startLine: 3, endLine: 4)
        XCTAssertEqual(hit, SourceClickResolver.Target(line: 4, column: 23))
    }

    func testRespectsWordBoundariesRatherThanSubstrings() {
        let text = "foxglove and a fox\n"
        let hit = SourceClickResolver.resolve(
            in: text, word: "fox", ordinal: 1, startLine: 1, endLine: 1)
        XCTAssertEqual(hit, SourceClickResolver.Target(line: 1, column: 16))
    }

    func testSkipsLinesOutsideTheClickedBlock() {
        // "dog" appears on line 3 too; the click was inside the table.
        let hit = SourceClickResolver.resolve(
            in: doc, word: "dog", ordinal: 1, startLine: 6, endLine: 9)
        XCTAssertEqual(hit?.line, 8)
    }

    func testFallsBackToTheLastOccurrenceWhenTheOrdinalOvershoots() {
        // Rendered text and source text can disagree (link URLs, entities), so an
        // ordinal past the end must still land on the right word.
        let hit = SourceClickResolver.resolve(
            in: doc, word: "fox", ordinal: 9, startLine: 3, endLine: 4)
        XCTAssertEqual(hit, SourceClickResolver.Target(line: 4, column: 23))
    }

    func testReturnsNilWhenTheWordIsAbsentFromTheBlock() {
        XCTAssertNil(SourceClickResolver.resolve(
            in: doc, word: "cat", ordinal: 1, startLine: 3, endLine: 4))
    }

    func testReturnsNilForAnEmptyWord() {
        XCTAssertNil(SourceClickResolver.resolve(
            in: doc, word: "", ordinal: 1, startLine: 3, endLine: 4))
    }

    func testHandlesNonASCIIWords() {
        let text = "Rød grød med fløde\nmere grød her\n"
        let hit = SourceClickResolver.resolve(
            in: text, word: "grød", ordinal: 2, startLine: 1, endLine: 2)
        XCTAssertEqual(hit, SourceClickResolver.Target(line: 2, column: 6))
    }

    func testColumnIsMeasuredInUTF16UnitsSoCodeMirrorAgrees() {
        // An emoji is two UTF-16 units; CodeMirror counts the same way.
        let text = "a 😀 target here\n"
        let hit = SourceClickResolver.resolve(
            in: text, word: "target", ordinal: 1, startLine: 1, endLine: 1)
        XCTAssertEqual(hit, SourceClickResolver.Target(line: 1, column: 6))
    }

    func testClampsOutOfRangeLineNumbers() {
        let hit = SourceClickResolver.resolve(
            in: doc, word: "Title", ordinal: 1, startLine: 0, endLine: 999)
        XCTAssertEqual(hit, SourceClickResolver.Target(line: 1, column: 3))
    }

    // The payloads below are the ones boot.js actually posts for these clicks,
    // captured by driving the real click handler in a browser.
    func testResolvesTheWordInsideATableCell() {
        let hit = SourceClickResolver.resolve(
            in: doc, word: "yip", ordinal: 1, startLine: 6, endLine: 9)
        XCTAssertEqual(hit, SourceClickResolver.Target(line: 9, column: 12))
    }

    func testOrdinalCountedAcrossASoftBreakMatchesTheSourceLine() {
        // "dog" ends line 3 and opens line 4; the preview counts both, so the
        // second one has to land on line 4.
        let hit = SourceClickResolver.resolve(
            in: doc, word: "dog", ordinal: 2, startLine: 3, endLine: 4)
        XCTAssertEqual(hit, SourceClickResolver.Target(line: 4, column: 5))
    }

    func testClampsNonPositiveOrdinalToTheFirstMatch() {
        let hit = SourceClickResolver.resolve(
            in: doc, word: "fox", ordinal: 0, startLine: 3, endLine: 4)
        XCTAssertEqual(hit, SourceClickResolver.Target(line: 3, column: 17))
    }
}
