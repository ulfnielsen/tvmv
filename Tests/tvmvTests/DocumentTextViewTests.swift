import XCTest
import AppKit
import TVMVCore
@testable import tvmv

@MainActor
final class DocumentTextViewTests: XCTestCase {
    private var window: NSWindow!
    private var view: DocumentTextView!
    private var patches: [TextPatcher.Patch] = []
    private let doc = "# Title\n\nSome **bold** and *em* text with [a link](https://example.com) and recieve.\n\n```swift\nlet wrongg = 1\n```\nafter\n"

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        view = DocumentTextView.make()
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = view
        window.contentView!.addSubview(scroll)
        patches = []
        view.onEdit = { [unowned self] patch, _ in patches.append(patch) }
        view.load(doc)
    }

    private func pump(_ seconds: Double = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Whether the glyph for character `index` is a null (hidden) glyph.
    private func glyphHidden(_ index: Int) -> Bool {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        return lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: index)).contains(.null)
    }

    private var ns: NSString { view.string as NSString }

    func testMarkupIsHiddenAndTheTextUntouched() {
        let bold = ns.range(of: "**bold**")
        XCTAssertTrue(glyphHidden(0))
        XCTAssertTrue(glyphHidden(bold.location))
        XCTAssertFalse(glyphHidden(bold.location + 2))
        XCTAssertEqual(view.string, doc)
    }

    func testColumnIsCenteredWithoutChangingTheViewWidth() {
        // Regression: centering via the inset must not make the view grow to
        // fit it (that loop pushed the column off to the right).
        let column = view.theme.columnWidth!
        view.setFrameSize(NSSize(width: 1400, height: 600))
        XCTAssertEqual(view.frame.width, 1400)
        XCTAssertEqual(view.textContainer!.size.width, column, accuracy: 1)
        XCTAssertEqual(view.textContainerInset.width, (1400 - column) / 2, accuracy: 1)

        view.setFrameSize(NSSize(width: 500, height: 600))
        XCTAssertEqual(view.frame.width, 500)
        XCTAssertEqual(view.textContainerInset.width, view.theme.padding, accuracy: 1)
        XCTAssertEqual(view.textContainer!.size.width, 500 - 2 * view.theme.padding, accuracy: 1)
    }

    func testCaretSnapsPastTheHeadingPrefix() {
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(view.selectedRange().location, 2)
    }

    func testRevealShowsOneSpanUntilTheSelectionLeaves() {
        let bold = ns.range(of: "**bold**")
        view.setSelectedRange(NSRange(location: bold.location + 3, length: 0))
        view.reveal(true)
        XCTAssertFalse(glyphHidden(bold.location))
        XCTAssertTrue(glyphHidden(0), "other spans stay hidden")

        view.setSelectedRange(NSRange(location: ns.range(of: "after").location, length: 0))
        pump()
        XCTAssertTrue(glyphHidden(bold.location))
        XCTAssertFalse(view.revealing)
    }

    func testShowAllMarkup() {
        view.showAllMarkup = true
        XCTAssertFalse(glyphHidden(0))
        view.showAllMarkup = false
        XCTAssertTrue(glyphHidden(0))
    }

    func testBackspaceAfterHiddenDelimiterDeletesTheVisibleCharacterAndUndoes() {
        view.isEditable = true
        window.makeFirstResponder(view)
        let em = ns.range(of: "*em*")
        view.setSelectedRange(NSRange(location: NSMaxRange(em), length: 0))
        view.deleteBackward(nil)
        pump()
        XCTAssertTrue(view.string.contains("*e* text"))
        XCTAssertEqual(patches.last, .init(from: NSMaxRange(em) - 2, to: NSMaxRange(em) - 1, insert: ""))
        view.undoManager?.undo()
        pump()
        XCTAssertEqual(view.string, doc)
    }

    func testTypedFormattingRendersImmediately() {
        view.isEditable = true
        let end = ns.range(of: "after").location + 5
        view.insertText(" *new*", replacementRange: NSRange(location: end, length: 0))
        pump()
        let em = ns.range(of: "*new*")
        XCTAssertTrue(glyphHidden(em.location))
        XCTAssertTrue(glyphHidden(NSMaxRange(em) - 1))
        XCTAssertFalse(glyphHidden(em.location + 1))
    }

    func testLinkUnderPoint() {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        let text = ns.range(of: "a link")
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: text.location + 1, length: 1), actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
        let point = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        XCTAssertEqual(view.link(at: point), "https://example.com")
    }

    func testSpellingExemptions() {
        // The live squiggles come from the system spell checker, which does
        // not run under XCTest; check the exemption the delegate consults.
        XCTAssertTrue(view.isSpellExempt(ns.range(of: "wrongg")))
        XCTAssertTrue(view.isSpellExempt(ns.range(of: "https://example.com")))
        XCTAssertFalse(view.isSpellExempt(ns.range(of: "recieve")))
        XCTAssertFalse(view.isSpellExempt(ns.range(of: "a link")))
    }

    func testLargeDocumentsParseOffTheMainThreadAndApply() {
        var big = ""
        while big.utf16.count < 300_000 { big += doc + "\n" }
        view.isEditable = true
        view.load(big)
        let before = view.layout.markers.count
        view.insertText("**x** ", replacementRange: NSRange(location: 9, length: 0))
        XCTAssertEqual(view.layout.markers.count, before, "not applied synchronously")
        let deadline = Date().addingTimeInterval(5)
        while view.layout.markers.count == before, Date() < deadline { pump() }
        XCTAssertEqual(view.layout.markers.count, before + 2)
    }

    // MARK: Final review regressions

    /// Characters currently hidden on screen vs. what a fresh parse of the
    /// current text says to hide. Equal means no stale layout is applied.
    private func hiddenMatchesAFreshParse() -> Bool {
        let storage = view.textStorage!
        var onScreen = IndexSet()
        storage.enumerateAttribute(.tvmvHidden, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { onScreen.insert(integersIn: range.location..<NSMaxRange(range)) }
        }
        var expected = IndexSet()
        for marker in MarkdownLayoutParser.parse(storage.string).markers {
            expected.insert(integersIn: marker.range.location..<NSMaxRange(marker.range))
        }
        return onScreen == expected
    }

    private func bigDocument() -> String {
        var big = ""
        while big.utf16.count < 300_000 { big += doc + "\n" }
        return big
    }

    func testBackspaceBesideHiddenMarkupKeepsAnEmojiWhole() {
        view.isEditable = true
        view.load("😀*a* end\n")
        view.setSelectedRange(NSRange(location: 3, length: 0))   // after the hidden opening "*"
        view.deleteBackward(nil)
        pump()
        XCTAssertEqual(view.string, "*a* end\n")
    }

    func testALoadDuringAnAsyncParseIsNotOverwrittenByIt() {
        view.isEditable = true
        view.load(bigDocument())
        view.insertText("**x** ", replacementRange: NSRange(location: 9, length: 0))   // parse in flight
        var other = ""
        while other.utf16.count < 300_000 { other += "An *other* text and a `code` span.\n\n" }
        view.load(other)
        pump(3)
        XCTAssertEqual(view.layout, MarkdownLayoutParser.parse(view.string))
        XCTAssertTrue(hiddenMatchesAFreshParse())
    }

    func testCompositionDuringAnAsyncParseKeepsHiddenRangesAligned() {
        view.isEditable = true
        view.load(bigDocument())
        window.makeFirstResponder(view)
        view.insertText("x", replacementRange: NSRange(location: 9, length: 0))   // parse in flight
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: 10, length: 0))
        pump(3)
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertTrue(hiddenMatchesAFreshParse(), "a layout for the pre-composition text was applied")
        view.unmarkText()
        pump(3)
        XCTAssertTrue(hiddenMatchesAFreshParse())
    }

    func testTypingInALargeDocumentRunsOneBackgroundParseAtATime() {
        // Final review: every keystroke above 64 KB started its own
        // uncancellable full parse; the newest result queued behind
        // obsolete work. One parse in flight, then one for the latest text.
        view.isEditable = true
        view.load(bigDocument())
        for i in 0..<5 {
            view.insertText("w", replacementRange: NSRange(location: 9 + i, length: 0))
        }
        XCTAssertEqual(view.backgroundParsesStarted, 1)
        let deadline = Date().addingTimeInterval(10)
        while view.layout != MarkdownLayoutParser.parse(view.string), Date() < deadline { pump() }
        XCTAssertEqual(view.layout, MarkdownLayoutParser.parse(view.string))
        XCTAssertLessThanOrEqual(view.backgroundParsesStarted, 2)
        XCTAssertTrue(hiddenMatchesAFreshParse())
    }

    // MARK: Parity with the web reader (app.css)

    /// Line fragments as (text, height), in order.
    private func fragments() -> [(text: String, height: CGFloat)] {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        var out: [(String, CGFloat)] = []
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { rect, _, _, glyphs, _ in
            let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            out.append((self.ns.substring(with: chars), rect.height))
        }
        return out
    }

    func testParagraphsReflowAcrossSoftLineBreaks() {
        view.load("one\ntwo\nthree\n\nnext\n")
        XCTAssertEqual(fragments().first?.text, "one\ntwo\nthree\n", "one visual line for the wrapped paragraph")
        XCTAssertEqual(view.string, "one\ntwo\nthree\n\nnext\n", "the text itself is untouched")
    }

    func testBodyLinesUseTheCSSLineHeightAndBlankLinesAreAOneEmGap() {
        // app.css: line-height 1.7; paragraphs separated by a 1em margin.
        view.load("first\n\nsecond\n")
        let size = view.theme.body.pointSize
        let lines = fragments()
        XCTAssertEqual(lines.map(\.text), ["first\n", "\n", "second\n"])
        XCTAssertEqual(lines[0].height, 1.7 * size, accuracy: 1)
        XCTAssertEqual(lines[1].height, 1.0 * size, accuracy: 1)
    }

    func testHeadingsAreRegularWeightAsInTheCSS() {
        let font = view.theme.headingFont(1)
        XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(font.pointSize, 2 * view.theme.body.pointSize, accuracy: 0.01)
    }

    func testTextIsDrawnWithoutFontSmoothingLikeTheWebReader() {
        // app.css sets -webkit-font-smoothing: antialiased; AppKit's default
        // smoothing thickens strokes, which reads as less crisp.
        view.load("Crisp text sample with plenty of strokes to measure.\n")
        func ink() -> Int {
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            var total = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                for y in 0..<min(rep.pixelsHigh, 200) {
                    total += Int((1 - (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1)) * 255)
                }
            }
            return total
        }
        XCTAssertFalse(view.fontSmoothing)
        let crisp = ink()
        view.fontSmoothing = true
        let smoothed = ink()
        XCTAssertLessThan(crisp, smoothed)
    }

    func testASoftBreakIsAsWideAsASpace() {
        // Reflowed words must not run together: "one\ntwo" reads "one two".
        view.load("one\ntwo\n")
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        func x(_ index: Int) -> CGFloat { lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: index)).x }
        let space = (" " as NSString).size(withAttributes: [.font: view.theme.body]).width
        let endOfOne = x(2) + ("e" as NSString).size(withAttributes: [.font: view.theme.body]).width
        XCTAssertEqual(x(4) - endOfOne, space, accuracy: 1)
    }

    func testInlineCodeBackgroundHugsTheTextNotTheLine() {
        // app.css: a code span gets a small padded pill (≈1.1em tall), not a
        // block filling the 1.7 line height. Measured down one pixel column
        // through the space inside the span, where there is no glyph ink.
        view.load("before `code span` after\n")
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        let space = ns.range(of: "code span").location + 4
        let glyphRect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: space, length: 1),
                                                                    actualCharacterRange: nil), in: view.textContainer!)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let column = Int((glyphRect.midX + view.textContainerOrigin.x) * scale)
        let paper = rep.colorAt(x: column, y: 2)!.brightnessComponent   // top margin: plain paper
        let tinted = (0..<rep.pixelsHigh).filter { y in
            abs((rep.colorAt(x: column, y: y)?.brightnessComponent ?? paper) - paper) > 0.004
        }
        let height = CGFloat(tinted.count) / scale
        let size = view.theme.body.pointSize
        XCTAssertGreaterThan(height, 0.8 * size, "the pill is drawn")
        XCTAssertLessThan(height, 1.4 * size, "the pill is \(height) pt tall")
    }
}
