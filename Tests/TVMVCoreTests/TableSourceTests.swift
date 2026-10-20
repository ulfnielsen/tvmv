import XCTest
@testable import TVMVCore

final class TableSourceTests: XCTestCase {
    private let text = "Intro.\n\n| Name | Score |\n|:-----|------:|\n| Ada  | 10 |\n| Bob | 7 |\n\nAfter.\n"

    private var table: MarkdownLayout.Table { MarkdownLayoutParser.parse(text).tables[0] }

    private func apply(_ patches: [TextPatcher.Patch]) -> String {
        TextPatcher.apply(patches, to: text)!
    }

    func testACellEditPatchesThatCellsSourceOnly() {
        // Typing "a" at the end of "Ada" (cell offset 3).
        let patch = TableSource.cellEdit(table, row: 1, column: 0, .init(from: 3, to: 3, insert: "m"))
        XCTAssertEqual(apply([patch]), text.replacingOccurrences(of: "| Ada  |", with: "| Adam  |"))
    }

    func testATypedPipeIsEscaped() {
        let patch = TableSource.cellEdit(table, row: 2, column: 1, .init(from: 1, to: 1, insert: "|"))
        XCTAssertEqual(apply([patch]), text.replacingOccurrences(of: "| 7 |", with: "| 7\\| |"))
    }

    func testCellTextIsItsSourceTextEscapesIncluded() {
        let escaped = "| A |\n|---|\n| x \\| y |\n"
        let t = MarkdownLayoutParser.parse(escaped).tables[0]
        XCTAssertEqual(TableSource.cellText(t, row: 1, column: 0, in: escaped as NSString), "x \\| y")
    }

    func testStructureChangesRewriteTheTableNeatly() {
        let addRow = TableSource.reformat(table, in: text as NSString) { cells, alignments in
            cells.insert(["", ""], at: 2)
        }
        XCTAssertEqual(apply([addRow]), """
        Intro.

        | Name | Score |
        | :--- | ----: |
        | Ada  |    10 |
        |      |       |
        | Bob  |     7 |

        After.

        """)

        let addColumn = TableSource.reformat(table, in: text as NSString) { cells, alignments in
            for i in cells.indices { cells[i].append(i == 0 ? "Note" : "") }
            alignments.append(.center)
        }
        XCTAssertEqual(apply([addColumn]), """
        Intro.

        | Name | Score | Note |
        | :--- | ----: | :--: |
        | Ada  |    10 |      |
        | Bob  |     7 |      |

        After.

        """)
    }

    func testReformatPadsByCharactersNotUTF16Units() {
        let wide = "| A | B |\n|---|---|\n| 😀 | é |\n"
        let t = MarkdownLayoutParser.parse(wide).tables[0]
        let patch = TableSource.reformat(t, in: wide as NSString) { _, _ in }
        XCTAssertEqual(TextPatcher.apply([patch], to: wide), "| A   | B   |\n| --- | --- |\n| 😀   | é   |\n")
    }
}
