import XCTest
import AppKit
import TVMVCore
@testable import tvmv

@MainActor
final class ListQuoteTests: XCTestCase {
    private var window: NSWindow!
    private var view: DocumentTextView!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        view = DocumentTextView.make()
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = view
        window.contentView!.addSubview(scroll)
    }

    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    private var ns: NSString { view.string as NSString }
    private var em: CGFloat { view.theme.body.pointSize }

    private func glyphHidden(_ index: Int) -> Bool {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        return lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: index)).contains(.null)
    }

    private func paragraphStyle(at index: Int) -> NSParagraphStyle? {
        view.textStorage!.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }

    func testBulletMarkersHideAndItemsHangByLevel() {
        view.load("- one\n  - nested\n- two\n")
        XCTAssertTrue(glyphHidden(0), "the '-' hides")
        XCTAssertTrue(glyphHidden(1))
        XCTAssertFalse(glyphHidden(2), "the text shows")
        let top = paragraphStyle(at: 2), nested = paragraphStyle(at: ns.range(of: "nested").location)
        XCTAssertEqual(top?.firstLineHeadIndent ?? 0, DocumentStyler.listIndent(level: 0, em: em), accuracy: 0.5)
        XCTAssertEqual(top?.headIndent ?? 0, DocumentStyler.listIndent(level: 0, em: em), accuracy: 0.5)
        XCTAssertEqual(nested?.firstLineHeadIndent ?? 0, DocumentStyler.listIndent(level: 1, em: em), accuracy: 0.5)
        XCTAssertTrue(glyphHidden(ns.range(of: "  - nested").location), "nested indentation hides too")
    }

    func testQuotePrefixesHideAndIndent() {
        view.load("> quoted\n>> deeper\n\nplain\n")
        XCTAssertTrue(glyphHidden(0))
        XCTAssertFalse(glyphHidden(2))
        XCTAssertEqual(paragraphStyle(at: 2)?.firstLineHeadIndent ?? 0, DocumentStyler.quoteIndent(level: 1, em: em), accuracy: 0.5)
        let deeper = ns.range(of: "deeper").location
        XCTAssertEqual(paragraphStyle(at: deeper)?.firstLineHeadIndent ?? 0, DocumentStyler.quoteIndent(level: 2, em: em), accuracy: 0.5)
    }

    func testCheckboxesToggleEvenWhileReadingAndUndo() {
        view.load("- [ ] todo\n- [x] done\n")
        XCTAssertFalse(view.isEditable)
        view.toggleTask(0)
        pump()
        XCTAssertEqual(view.string, "- [x] todo\n- [x] done\n")
        XCTAssertFalse(view.isEditable, "still reading")
        view.toggleTask(1)
        pump()
        XCTAssertEqual(view.string, "- [x] todo\n- [ ] done\n")
        XCTAssertTrue(view.tryToPerform(Selector(("undo:")), with: nil))   // Edit ▸ Undo, still reading
        pump()
        XCTAssertEqual(view.string, "- [x] todo\n- [x] done\n")
    }

    func testClickingAChecklistBoxFindsItsItem() {
        view.load("Intro.\n\n- [ ] todo\n")
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        let text = ns.range(of: "todo").location
        let fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: text), effectiveRange: nil)
        let box = view.taskBoxRect(for: view.layout.listItems[0])!
        XCTAssertEqual(view.taskItem(at: NSPoint(x: box.midX, y: box.midY)), 0)
        XCTAssertNil(view.taskItem(at: NSPoint(x: box.maxX + 40, y: fragment.midY + view.textContainerOrigin.y)))
    }

    func testReturnContinuesListsAndQuotes() {
        view.isEditable = true
        window.makeFirstResponder(view)
        for (text, expected) in [("- a\n", "- a\n- \n"), ("3) x\n", "3) x\n4) \n"), ("- [x] t\n", "- [x] t\n- [ ] \n"),
                                 ("  - n\n", "  - n\n  - \n"), ("> q\n", "> q\n> \n")] {
            view.load(text)
            view.setSelectedRange(NSRange(location: (text as NSString).length - 1, length: 0))
            view.insertNewline(nil)
            pump()
            XCTAssertEqual(view.string, expected, "Return in «\(text)»")
            XCTAssertEqual(view.selectedRange().location, (expected as NSString).length - 1, "caret after the new marker")
        }
    }

    func testReturnOnAnEmptyItemEndsTheList() {
        view.isEditable = true
        window.makeFirstResponder(view)
        view.load("- a\n- \n")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.insertNewline(nil)
        pump()
        XCTAssertEqual(view.string, "- a\n\n")
    }

    /// x of the character at `index`, in view coordinates.
    private func x(_ index: Int) -> CGFloat {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        let glyph = lm.glyphIndexForCharacter(at: index)
        let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return fragment.minX + lm.location(forGlyphAt: glyph).x
    }

    func testShowingMarkdownDoesNotMoveListOrQuoteText() {
        // Reported: bullets/text moved just by showing the Markdown. The
        // revealed marker takes the bullet's place; the text stays put.
        view.load("- one\n  - nested\n3) third\n- [ ] task\n> quoted\n")
        let words = ["one", "nested", "third", "task", "quoted"].map { ns.range(of: $0).location }
        let hidden = words.map(x)
        view.showAllMarkup = true
        let shown = words.map(x)
        for (i, word) in ["one", "nested", "third", "task", "quoted"].enumerated() {
            XCTAssertEqual(shown[i], hidden[i], accuracy: 0.5, "«\(word)» moved")
        }
        view.showAllMarkup = false
        XCTAssertEqual(words.map(x), hidden, "and back")
    }

    func testEveryItemGetsItsOwnBulletWhenItsTextStartsWithMarkup() {
        // Reported: a three-item list whose items start with an italic word
        // showed two bullets. Hidden glyphs at a line's start sit on the line
        // before, so the bullet was drawn there.
        for text in ["- *one* a\n- *two* b\n- **three** c\n", "1. _one_\n2. _two_\n3. _three_\n",
                     "Intro.\n\n* *one* a\n* *two* b\n* *three* c\n"] {
            view.load(text)
            let rows = view.layout.listItems.compactMap { view.bulletAnchor(for: $0)?.y }
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual(Set(rows.map { Int($0) }).count, 3, "three distinct lines in «\(text)»: \(rows)")
            XCTAssertEqual(rows, rows.sorted())
        }
    }

    func testCheckedAndOpenTasksLineUp() {
        view.load("- [x] done\n- [ ] open\n")
        XCTAssertEqual(x(ns.range(of: "done").location), x(ns.range(of: "open").location), accuracy: 0.5)
    }

    /// Count pixels differing from the paper in `rect` when only `rect` is
    /// redrawn — what scrolling does, a thin strip at a time.
    private func inkInStrip(_ rect: NSRect) -> Int {
        let rep = view.bitmapImageRepForCachingDisplay(in: rect)!
        view.cacheDisplay(in: rect, to: rep)
        let paper = view.theme.paper.usingColorSpace(.deviceRGB)!
        var ink = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if abs(c.redComponent - paper.redComponent) + abs(c.greenComponent - paper.greenComponent)
                + abs(c.blueComponent - paper.blueComponent) > 0.3 { ink += 1 }
        } }
        return ink
    }

    func testABulletIsDrawnWhenOnlyItsLineIsRedrawn() {
        // Reported: bullets vanished while scrolling. Scrolling redraws a strip;
        // an item whose "*" sits on the line before must still get its bullet.
        view.load("Intro.\n\n- *one* a\n- *two* b\n- plain c\n")
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        for item in view.layout.listItems {
            let anchor = view.bulletAnchor(for: item)!
            let strip = NSRect(x: 0, y: anchor.y - em, width: anchor.x, height: em * 1.2)
            XCTAssertGreaterThan(inkInStrip(strip), 0, "bullet at \(anchor) drawn in a strip redraw")
        }
    }
}
