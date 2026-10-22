import XCTest
import AppKit
import TVMVCore
@testable import tvmv

@MainActor
final class TableGridTests: XCTestCase {
    private var window: NSWindow!
    private var view: DocumentTextView!
    private let doc = "Intro.\n\n| Name | Score |\n|:-----|------:|\n| Ada  | 10 |\n| Bob | 7 |\n\nAfter.\n"

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        view = DocumentTextView.make()
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = view
        window.contentView!.addSubview(scroll)
        view.load(doc)
        view.layoutManager!.ensureLayout(for: view.textContainer!)
    }

    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    private var ns: NSString { view.string as NSString }
    private var grid: TableGridView { view.tableGrids[0] }

    private func glyphHidden(_ index: Int) -> Bool {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        return lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: index)).contains(.null)
    }

    func testATableShowsAsAGridOverItsHiddenSource() {
        XCTAssertEqual(view.tableGrids.count, 1)
        XCTAssertEqual(grid.cellTexts, [["Name", "Score"], ["Ada", "10"], ["Bob", "7"]])
        XCTAssertFalse(grid.isHidden)
        let source = ns.range(of: "| Name")
        XCTAssertTrue(glyphHidden(source.location))
        XCTAssertTrue(glyphHidden(ns.range(of: "| Bob").location))
    }

    func testCellsPostNoFrameChanges() {
        // Posting costs more with every text view: with each cell posting,
        // a page of tables took quadratic time to load.
        XCTAssertTrue(grid.cells.joined().allSatisfy { !$0.postsFrameChangedNotifications })
        XCTAssertTrue(view.postsFrameChangedNotifications, "the document's scroll view follows its frame")
    }

    func testTheGridReservesItsHeightAndFitsTheColumn() {
        // The table's first line is all hidden glyphs, which TextKit puts on
        // the line before; the reserved height lands on the line that starts
        // at the first line's newline — the grid must sit on that line.
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        let newline = NSMaxRange(ns.lineRange(for: NSRange(location: ns.range(of: "| Name").location, length: 0))) - 1
        let reserved = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: newline), effectiveRange: nil)
        XCTAssertEqual(reserved.height, grid.frame.height + view.theme.body.pointSize, accuracy: 1)
        XCTAssertEqual(grid.frame.minY, reserved.minY + view.textContainerOrigin.y + view.theme.body.pointSize / 2, accuracy: 1)
        XCTAssertLessThanOrEqual(grid.frame.width, view.textContainer!.size.width)
        XCTAssertGreaterThan(grid.frame.height, 3 * view.theme.body.pointSize)
    }

    func testTypingInACellEditsTheSourceAndUndoesInOneStep() {
        view.isEditable = true
        let cell = grid.cell(row: 1, column: 0)
        window.makeFirstResponder(cell)
        cell.setSelectedRange(NSRange(location: 3, length: 0))
        cell.insertText("m", replacementRange: cell.selectedRange())
        pump()
        XCTAssertTrue(view.string.contains("| Adam  |"), view.string)
        XCTAssertEqual(grid.cellTexts[1][0], "Adam")
        cell.tryToPerform(Selector(("undo:")), with: nil)
        pump()
        XCTAssertEqual(view.string, doc)
        XCTAssertEqual(grid.cellTexts[1][0], "Ada")
    }

    func testATypedPipeIsEscapedInTheSource() {
        view.isEditable = true
        let cell = grid.cell(row: 2, column: 1)
        window.makeFirstResponder(cell)
        cell.setSelectedRange(NSRange(location: 1, length: 0))
        cell.insertText("|", replacementRange: cell.selectedRange())
        pump()
        XCTAssertTrue(view.string.contains("| 7\\| |"), view.string)
    }

    func testTabShiftTabAndReturnMoveBetweenCells() {
        view.isEditable = true
        window.makeFirstResponder(grid.cell(row: 1, column: 0))
        grid.cell(row: 1, column: 0).insertTab(nil)
        XCTAssertTrue(window.firstResponder === grid.cell(row: 1, column: 1))
        grid.cell(row: 1, column: 1).insertTab(nil)
        XCTAssertTrue(window.firstResponder === grid.cell(row: 2, column: 0), "wraps to the next row")
        grid.cell(row: 2, column: 0).insertBacktab(nil)
        XCTAssertTrue(window.firstResponder === grid.cell(row: 1, column: 1))
        grid.cell(row: 1, column: 1).insertNewline(nil)
        XCTAssertTrue(window.firstResponder === grid.cell(row: 2, column: 1), "Return moves down")
        XCTAssertEqual(view.string, doc, "navigation never edits")
    }

    func testAddingARowRewritesTheTable() {
        view.isEditable = true
        grid.insertRow(below: 1)
        pump()
        XCTAssertTrue(view.string.contains("| Ada  |    10 |\n|      |       |\n| Bob  |     7 |"), view.string)
        XCTAssertEqual(grid.cellTexts.count, 4)
    }

    func testRevealFromACellShowsTheRawSource() {
        view.isEditable = true
        let cell = grid.cell(row: 1, column: 0)
        window.makeFirstResponder(cell)
        cell.toggleRevealMarkup(nil)
        pump()
        XCTAssertFalse(glyphHidden(ns.range(of: "| Name").location))
        XCTAssertTrue(grid.isHidden)
        XCTAssertTrue(window.firstResponder === view)
    }

    func testCellsAreReadOnlyUntilEditingIsOn() {
        XCTAssertFalse(grid.cell(row: 1, column: 0).isEditable)
        view.isEditable = true
        XCTAssertTrue(grid.cell(row: 1, column: 0).isEditable)
    }

    func testColumnsTakeTheirContentsWidthAndRowsStayOneLineWhenThereIsRoom() {
        // Regression: cells measured at their unsized frame's width came out
        // at the 48 pt minimum, wrapping a letter or two per line.
        let lineHeight = 1.7 * view.theme.body.pointSize + 2 * TableGridView.cellInset.height
        for row in 0..<3 {
            XCTAssertLessThanOrEqual(grid.cell(row: row, column: 0).frame.height, lineHeight + 1, "row \(row)")
        }
        XCTAssertGreaterThan(grid.cell(row: 0, column: 0).frame.width,
                             ("Name" as NSString).size(withAttributes: [.font: view.theme.body]).width)
    }

    func testHiddenTableSourceDrawsNoCodePills() {
        // Regression: the document drew an inline-code pill for a code span
        // inside a table's hidden source, a sliver just below the grid.
        view.load("Text `outside`.\n\n| A |\n|---|\n| `inside` |\n\nAfter.\n")
        let pills = view.codePillRuns().map { (view.string as NSString).substring(with: $0.range) }
        XCTAssertEqual(pills, ["outside"])
        let cell = view.tableGrids[0].cell(row: 1, column: 0)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.reveal(unit: view.layout.tables[0].range)
        XCTAssertEqual(view.codePillRuns().count, 2, "a revealed table's source draws as text again")
        _ = cell
    }

    func testTheGridStaysAlignedWithTheTextWhenTheWindowWidens() {
        // Reported: beyond the measure the text column recentres, the table
        // stayed where it was (it only moved when the column width changed).
        for width: CGFloat in [1600, 2400, 900] {
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
            let textLeft = view.textContainerOrigin.x + view.textContainer!.lineFragmentPadding
            XCTAssertEqual(grid.frame.minX, textLeft, accuracy: 0.5, "at \(width) pt")
        }
    }

    // MARK: Icons and shortcuts

    func testCellMenuItemsHaveIconsAndShortcuts() {
        view.isEditable = true
        view.layoutGrids()
        let items = grid.menuItems(for: grid.cell(row: 1, column: 0)).filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.count, TableCommand.allCases.count)
        for item in items {
            XCTAssertNotNil(item.image, "an icon for «\(item.title)»")
            XCTAssertFalse(item.keyEquivalent.isEmpty, "a shortcut for «\(item.title)»")
        }
        for command in TableCommand.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil), command.symbol)
        }
    }

    func testTableCommandsActOnTheFocusedCell() {
        view.isEditable = true
        view.layoutGrids()
        let cell = grid.cell(row: 1, column: 0)
        cell.performTableCommand(TableCommand.insertRowBelow.menuItem())
        XCTAssertEqual(grid.cellTexts, [["Name", "Score"], ["Ada", "10"], ["", ""], ["Bob", "7"]])
        grid.cell(row: 1, column: 1).performTableCommand(TableCommand.insertColumnRight.menuItem())
        XCTAssertEqual(grid.cellTexts.map(\.count), [3, 3, 3, 3])
        grid.cell(row: 1, column: 0).performTableCommand(TableCommand.alignCenter.menuItem())
        let delimiter = view.string.split(separator: "\n").first { $0.hasPrefix("|:") || $0.hasPrefix("| :") }!
        let first = delimiter.split(separator: "|").first!.trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(first.hasPrefix(":") && first.hasSuffix(":"), "centred: \(delimiter)")
    }

    func testTableCommandsOutsideATableDoNothing() {
        view.isEditable = true
        let before = view.string
        view.performTableCommand(TableCommand.insertRowBelow.menuItem())
        XCTAssertEqual(view.string, before)
    }

    // MARK: Hover controls

    /// The centre of cell (r, c), in the grid's coordinates.
    private func center(_ r: Int, _ c: Int) -> NSPoint {
        let f = grid.cell(row: r, column: c).frame
        return NSPoint(x: f.midX, y: f.midY)
    }

    func testHoveringACellShowsControlsOnItsBorders() {
        view.isEditable = true
        view.layoutGrids()
        grid.hover(at: center(1, 0))
        let c = grid.hoverControls
        XCTAssertTrue(c.allSatisfy { $0.superview === view && !$0.isHidden })
        let gridFrame = grid.frame
        let cell = grid.cell(row: 1, column: 0).frame.offsetBy(dx: gridFrame.minX, dy: gridFrame.minY)
        // Column controls above the grid; row controls left of it.
        XCTAssertLessThan(grid.columnHandle.frame.maxY, gridFrame.minY + 1)
        XCTAssertEqual(grid.columnHandle.frame.midX, cell.midX, accuracy: 1)
        XCTAssertEqual(grid.addColumnRight.frame.midX, cell.maxX, accuracy: 1)
        XCTAssertLessThan(grid.rowHandle.frame.maxX, gridFrame.minX + 1)
        XCTAssertEqual(grid.rowHandle.frame.midY, cell.midY, accuracy: 1)
        XCTAssertEqual(grid.addRowBelow.frame.midY, cell.maxY, accuracy: 1)
        grid.hover(at: nil)
        XCTAssertTrue(grid.hoverControls.allSatisfy(\.isHidden))
    }

    func testThePlusButtonsInsertWhereTheySit() {
        view.isEditable = true
        view.layoutGrids()
        grid.hover(at: center(1, 0))
        grid.addRowBelow.performClick(nil)
        XCTAssertEqual(grid.cellTexts, [["Name", "Score"], ["Ada", "10"], ["", ""], ["Bob", "7"]])
        grid.hover(at: center(1, 0))
        grid.addColumnRight.performClick(nil)
        XCTAssertEqual(grid.cellTexts[0], ["Name", "", "Score"])
        grid.hover(at: center(1, 0))
        grid.addColumnLeft.performClick(nil)
        XCTAssertEqual(grid.cellTexts[0], ["", "Name", "", "Score"])
    }

    func testTheHandlesOfferTheRestAndTheHeaderStays() {
        view.isEditable = true
        view.layoutGrids()
        grid.hover(at: center(1, 1))
        XCTAssertEqual(grid.columnMenu().items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Insert Column Left", "Insert Column Right", "Delete Column",
                        "Align Column Left", "Align Column Center", "Align Column Right"])
        XCTAssertEqual(grid.rowMenu().items.map(\.title), ["Insert Row Above", "Insert Row Below", "Delete Row"])
        grid.hover(at: center(0, 0))
        XCTAssertTrue(grid.addRowAbove.isHidden, "nothing goes above the header")
        XCTAssertEqual(grid.rowMenu().items.map(\.title), ["Insert Row Below"])
    }

    func testNoControlsWhileReading() {
        view.isEditable = false
        view.layoutGrids()
        grid.hover(at: center(1, 0))
        XCTAssertTrue(grid.hoverControls.allSatisfy(\.isHidden))
    }

    func testMovingThePointerOverTheTableShowsTheControls() {
        view.isEditable = true
        view.layoutGrids()
        let point = view.convert(NSPoint(x: grid.frame.minX + center(1, 0).x, y: grid.frame.minY + center(1, 0).y), to: nil)
        view.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 0, pressure: 0)!)
        XCTAssertFalse(grid.columnHandle.isHidden)
        let away = view.convert(NSPoint(x: grid.frame.minX, y: grid.frame.maxY + 200), to: nil)
        view.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: away, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 0, pressure: 0)!)
        XCTAssertTrue(grid.columnHandle.isHidden)
    }
}
