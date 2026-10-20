import XCTest
import AppKit
import TVMVCore
@testable import tvmv

@MainActor
final class ReviewViewTests: XCTestCase {
    private var window: NSWindow!
    private var view: DocumentTextView!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        view = DocumentTextView.make()
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = view
        window.contentView!.addSubview(scroll)
    }

    private var ns: NSString { view.string as NSString }

    private func attribute(_ key: NSAttributedString.Key, of word: String) -> Any? {
        view.textStorage!.attribute(key, at: ns.range(of: word).location, effectiveRange: nil)
    }

    private func glyphHidden(_ index: Int) -> Bool {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        return lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: index)).contains(.null)
    }

    static let doc = """
        The {==cache==}[^rv-a1b2] is {++warm++}[^rv-c3d4] and {--cold--}[^rv-e5f6], \
        {~~was~>is~~}[^rv-g7h8] here.[^rv-i9j0]

        [^rv-a1b2]: @ulf 2026-10-14: Why?
        [^rv-c3d4]: @ulf 2026-10-14 suggestion: a
        [^rv-e5f6]: @ulf 2026-10-14 suggestion: b
        [^rv-g7h8]: @ulf 2026-10-14 suggestion: c
        [^rv-i9j0]: @ulf 2026-10-14: Source?

        """

    func testAnchorsAreStyledByKind() {
        view.load(Self.doc)
        let theme = view.theme
        XCTAssertEqual(attribute(.backgroundColor, of: "cache") as? NSColor, theme.reviewHighlight)
        XCTAssertEqual(attribute(.foregroundColor, of: "warm") as? NSColor, theme.reviewInsert)
        XCTAssertNotNil(attribute(.underlineStyle, of: "warm"))
        XCTAssertEqual(attribute(.foregroundColor, of: "cold") as? NSColor, theme.reviewDelete)
        XCTAssertNotNil(attribute(.strikethroughStyle, of: "cold"))
        XCTAssertNotNil(attribute(.strikethroughStyle, of: "was"))
        XCTAssertNil(attribute(.underlineStyle, of: "was"))
        XCTAssertNotNil(attribute(.underlineStyle, of: "is~~"))
        XCTAssertGreaterThan(view.textStorage!.attribute(.kern, at: ns.range(of: "was").location + 2,
                                                        effectiveRange: nil) as? CGFloat ?? 0, 0,
                             "a gap between the old and the new text")
        XCTAssertEqual(attribute(.tvmvReview, of: "cache") as? String, "rv-a1b2")
    }

    func testMarkupAndThreadsHide() {
        view.load(Self.doc)
        XCTAssertTrue(glyphHidden(ns.range(of: "{==").location))
        XCTAssertTrue(glyphHidden(ns.range(of: "[^rv-a1b2]").location))
        XCTAssertFalse(glyphHidden(ns.range(of: "cache").location))
        XCTAssertTrue(glyphHidden(ns.range(of: "[^rv-a1b2]: @ulf").location + 12), "threads collapse")
        XCTAssertFalse(view.isSpellExempt(ns.range(of: "cache")))
        XCTAssertTrue(view.isSpellExempt(ns.range(of: "Why?")))
    }

    func testAPointCommentLeavesAClearCarrierForItsMarker() {
        view.load(Self.doc)
        let carrier = ns.range(of: "[^rv-i9j0]").location
        XCTAssertFalse(glyphHidden(carrier))
        XCTAssertTrue(glyphHidden(carrier + 1))
        XCTAssertEqual(view.textStorage!.attribute(.foregroundColor, at: carrier, effectiveRange: nil) as? NSColor, .clear)
        XCTAssertEqual(view.textStorage!.attribute(.tvmvReview, at: carrier, effectiveRange: nil) as? String, "rv-i9j0")
    }

    func testRevealingAnAnchorShowsItsMarkup() {
        view.load(Self.doc)
        view.reveal(unit: ns.range(of: "{==cache==}[^rv-a1b2]"))
        XCTAssertFalse(glyphHidden(ns.range(of: "{==").location))
        XCTAssertFalse(glyphHidden(ns.range(of: "[^rv-a1b2]").location))
    }

    func testAPointCommentDrawsAMarker() {
        view.load(Self.doc)
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        let carrier = lm.glyphIndexForCharacter(at: ns.range(of: "[^rv-i9j0]").location)
        var box = lm.boundingRect(forGlyphRange: NSRange(location: carrier, length: 1), in: view.textContainer!)
        box = box.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y).insetBy(dx: -2, dy: -4)
        let bitmap = view.bitmapImageRepForCachingDisplay(in: NSIntegralRect(box))!
        view.cacheDisplay(in: NSIntegralRect(box), to: bitmap)
        let accent = view.theme.accent.usingColorSpace(.deviceRGB)!
        var hits = 0
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if abs(c.redComponent - accent.redComponent) + abs(c.greenComponent - accent.greenComponent)
                + abs(c.blueComponent - accent.blueComponent) < 0.3 { hits += 1 }   // color profiles differ
        } }
        XCTAssertGreaterThan(hits, 10, "an accent marker where the point comment is")
    }

    // MARK: Actions

    private let day = Date(timeIntervalSince1970: 1_760_400_000)   // 2025-10-14, UTC

    func testCommentingOnTheSelectionIsOneUndoableEditWhileReading() {
        view.load("The cache is cold.\n")
        var edits = 0
        view.onEdit = { _, _ in edits += 1 }
        view.isEditable = false
        view.setSelectedRange(ns.range(of: "cache"))
        let id = view.addComment(body: "Why?", author: "ulf", date: day, timeZone: .gmt)
        XCTAssertNotNil(id)
        XCTAssertEqual(view.string, "The {==cache==}[^\(id!)] is cold.\n\n[^\(id!)]: @ulf 2025-10-14: Why?\n")
        XCTAssertFalse(view.isEditable, "still reading")
        XCTAssertGreaterThan(edits, 0, "the document saw the edit")
        view.undo(nil)   // as Edit > Undo does, while reading too
        XCTAssertEqual(view.string, "The cache is cold.\n")
    }

    func testSuggestingReplacesTheSelection() {
        view.load("The cache is cold.\n")
        view.setSelectedRange(ns.range(of: "cold"))
        let id = view.addSuggestion(replacement: "warm", body: "", author: "ulf", date: day, timeZone: .gmt)!
        XCTAssertTrue(view.string.hasPrefix("The cache is {~~cold~>warm~~}[^\(id)]."))
    }

    func testSettlingAThread() {
        view.load(Self.doc)
        XCTAssertTrue(view.settle("rv-a1b2", .resolve))
        XCTAssertFalse(view.string.contains("rv-a1b2"))
        XCTAssertTrue(view.string.hasPrefix("The cache is"))
        XCTAssertTrue(view.settle("rv-c3d4", .accept))
        XCTAssertTrue(view.string.hasPrefix("The cache is warm and"))
        XCTAssertTrue(view.settle("rv-e5f6", .reject))
        XCTAssertTrue(view.string.hasPrefix("The cache is warm and cold,"))
        XCTAssertFalse(view.settle("rv-nope", .resolve), "nothing to settle")
    }

    func testReplyingAppendsToTheThread() {
        view.load(Self.doc)
        XCTAssertTrue(view.reply(to: "rv-a1b2", body: "Because.", author: "claude", date: day, timeZone: .gmt))
        XCTAssertTrue(view.string.contains("[^rv-a1b2]: @ulf 2026-10-14: Why?\n    @claude 2025-10-14: Because.\n"))
    }

    func testACommentNeedsASelectionWithinOneBlock() {
        view.load("One.\n\nTwo.\n")
        view.setSelectedRange(NSRange(location: 0, length: ns.length))
        XCTAssertNil(view.addComment(body: "x", author: "ulf", date: day))
        XCTAssertEqual(view.string, "One.\n\nTwo.\n")
    }

    func testTheAuthorHandleIsTheFirstNameLowercased() {
        XCTAssertEqual(ReviewAuthor.handle(gitName: "Ulf Nielsen", account: "un"), "ulf")
        XCTAssertEqual(ReviewAuthor.handle(gitName: "  ", account: "un"), "un")
        XCTAssertEqual(ReviewAuthor.handle(gitName: nil, account: "Un"), "un")
    }
}
