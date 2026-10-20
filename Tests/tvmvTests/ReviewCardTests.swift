import XCTest
import AppKit
import TVMVCore
@testable import tvmv

@MainActor
final class ReviewCardTests: XCTestCase {
    private var window: NSWindow!
    private var view: DocumentTextView!

    private func makeView(width: CGFloat, fullWidth: Bool = false) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        view = DocumentTextView.make()
        view.theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16,
                                 measure: 70, fullWidth: fullWidth, dark: false)
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = view
        window.contentView!.addSubview(scroll)
    }

    private var ns: NSString { view.string as NSString }

    static let doc = """
        Intro paragraph.

        The {==cache==}[^rv-a1b2] is {~~cold~>warm~~}[^rv-c3d4] today.

        Another line with a point.[^rv-e5f6]

        [^rv-a1b2]: @ulf 2026-10-14: Why?
            @claude 2026-10-14: Because.
        [^rv-c3d4]: @claude 2026-10-14 suggestion: Warmer.
        [^rv-e5f6]: @ulf 2026-10-14: Source?

        """

    func testOneCardPerThreadInSourceOrder() {
        let review = ReviewMarkup.parse(Self.doc)
        let cards = ReviewCards.models(review)
        XCTAssertEqual(cards.map(\.id), ["rv-a1b2", "rv-c3d4", "rv-e5f6"])
        XCTAssertEqual(cards.map(\.kind), [.comment, .suggestion, .comment])
        XCTAssertEqual(cards[0].entries.map(\.author), ["ulf", "claude"])
    }

    func testProblemsGetTheirOwnCards() {
        let text = "A {==b==}[^rv-zzzz] c.\n\n[^rv-yyyy]: @ulf 2026-10-14: Lost.\n"
        let cards = ReviewCards.models(ReviewMarkup.parse(text))
        XCTAssertEqual(Set(cards.map(\.kind)), [.danglingAnchor, .orphanThread])
    }

    func testCardsSitBesideTheirAnchorsWithoutOverlapping() {
        makeView(width: 1500)
        view.load(Self.doc)
        let cards = view.reviewCards
        XCTAssertEqual(cards.map(\.id), ["rv-a1b2", "rv-c3d4", "rv-e5f6"])
        let column = view.textContainerOrigin.x + view.textContainer!.size.width
        for card in cards { XCTAssertGreaterThan(card.frame.minX, column, "in the right margin") }
        for (a, b) in zip(cards, cards.dropFirst()) { XCTAssertLessThanOrEqual(a.frame.maxY, b.frame.minY) }
        // The first card starts on its anchor's line.
        let lm = view.layoutManager!
        let line = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: ns.range(of: "cache").location),
                                       effectiveRange: nil)
        XCTAssertEqual(cards[0].frame.minY, line.minY + view.textContainerOrigin.y, accuracy: 1)
        XCTAssertTrue(view.reviewMarkers.isEmpty)
    }

    func testCardButtonsSettleAndReply() {
        makeView(width: 1500)
        view.load(Self.doc)
        view.reviewCards.first { $0.id == "rv-c3d4" }!.button("Accept")!.performClick(nil)
        XCTAssertTrue(view.string.contains("is warm today."))
        XCTAssertEqual(view.reviewCards.map(\.id), ["rv-a1b2", "rv-e5f6"])

        let card = view.reviewCards.first { $0.id == "rv-e5f6" }!
        card.replyField.stringValue = "Added one."
        card.submitReply()
        XCTAssertTrue(view.string.contains("[^rv-e5f6]: @ulf 2026-10-14: Source?\n    @"))
        XCTAssertTrue(view.string.contains(": Added one.\n"))

        view.reviewCards.first { $0.id == "rv-a1b2" }!.button("Resolve")!.performClick(nil)
        XCTAssertFalse(view.string.contains("rv-a1b2"))
    }

    func testAProblemCardFixesItsProblem() {
        makeView(width: 1500)
        view.load("A b c.\n\n[^rv-yyyy]: @ulf 2026-10-14: Lost.\n")
        view.reviewCards.first!.button("Delete Thread")!.performClick(nil)
        XCTAssertEqual(view.string, "A b c.\n")
    }

    func testANarrowWindowShowsMarkersThatOpenTheCard() {
        makeView(width: 700, fullWidth: true)
        view.load(Self.doc)
        XCTAssertTrue(view.reviewCards.allSatisfy(\.isHidden) || view.reviewCards.isEmpty)
        XCTAssertEqual(view.reviewMarkers.count, 3)
        let column = view.textContainerOrigin.x + view.textContainer!.size.width
        XCTAssertGreaterThanOrEqual(view.reviewMarkers[0].frame.minX, column)
        XCTAssertLessThanOrEqual(view.reviewMarkers[0].frame.maxX, view.bounds.width)
        window.orderFront(nil)   // a popover shows from a window on screen
        view.reviewMarkers[0].performClick(nil)
        XCTAssertEqual(view.reviewPopover?.isShown, true)
    }

    func testTheCaretInAnAnchorFocusesItsCard() {
        makeView(width: 1500)
        view.load(Self.doc)
        view.setSelectedRange(NSRange(location: ns.range(of: "cache").location + 2, length: 0))
        XCTAssertEqual(view.reviewCards.filter(\.isFocused).map(\.id), ["rv-a1b2"])
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(view.reviewCards.allSatisfy { !$0.isFocused })
    }

    // MARK: Creating and navigating

    /// Type into a field as a person would: into its live editor when it has one.
    private func type(_ text: String, into field: NSTextField) {
        if let editor = field.currentEditor() as? NSTextView { editor.string = text } else { field.stringValue = text }
    }

    func testCommentComposerAddsACommentOnTheSelection() {
        makeView(width: 1500)
        window.orderFront(nil)
        view.load("The cache is cold.\n")
        view.isEditable = false
        view.setSelectedRange(ns.range(of: "cache"))
        view.addReviewComment(nil)
        let composer = view.reviewComposer!
        XCTAssertEqual(view.reviewComposerPopover?.isShown, true)
        XCTAssertNil(composer.replacementField, "a comment has no replacement")
        type("Why?", into: composer.bodyField)
        composer.submit()
        XCTAssertTrue(view.string.hasPrefix("The {==cache==}[^rv-"))
        XCTAssertTrue(view.string.contains(": Why?\n"))
        XCTAssertNotEqual(view.reviewComposerPopover?.isShown, true)
    }

    func testSuggestionComposerStartsFromTheSelectedText() {
        makeView(width: 1500)
        window.orderFront(nil)
        view.load("The cache is cold.\n")
        view.setSelectedRange(ns.range(of: "cold"))
        view.suggestReviewEdit(nil)
        let composer = view.reviewComposer!
        XCTAssertEqual(composer.replacementField?.stringValue, "cold")
        // Leaving the field (Tab to the note) doesn't submit.
        window.makeFirstResponder(composer.bodyField)
        window.makeFirstResponder(nil)
        XCTAssertEqual(view.string, "The cache is cold.\n")
        type("warm", into: composer.replacementField!)
        composer.submit()
        XCTAssertTrue(view.string.hasPrefix("The cache is {~~cold~>warm~~}[^rv-"))
    }

    func testAComposerThatCannotPlaceItsCommentSaysSo() {
        makeView(width: 1500)
        window.orderFront(nil)
        view.load("One.\n\nTwo.\n")
        view.setSelectedRange(NSRange(location: 0, length: ns.length))
        view.addReviewComment(nil)
        type("x", into: view.reviewComposer!.bodyField)
        view.reviewComposer!.submit()
        XCTAssertEqual(view.string, "One.\n\nTwo.\n")
        XCTAssertFalse(view.reviewComposer!.messageLabel.stringValue.isEmpty)
    }

    func testNextAndPreviousThreadMoveTheCaret() {
        makeView(width: 1500)
        view.load(Self.doc)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.nextReviewThread(nil)
        XCTAssertEqual(view.selectedRange().location, ns.range(of: "cache").location)
        view.nextReviewThread(nil)
        XCTAssertEqual(view.selectedRange().location, ns.range(of: "cold").location)
        view.previousReviewThread(nil)
        XCTAssertEqual(view.selectedRange().location, ns.range(of: "cache").location)
        XCTAssertEqual(view.reviewCards.filter(\.isFocused).map(\.id), ["rv-a1b2"])
    }

    func testAcceptAllSettlesSuggestionsOnly() {
        makeView(width: 1500)
        view.load(Self.doc)
        view.acceptAllSuggestions(nil)
        XCTAssertTrue(view.string.contains("is warm today."))
        XCTAssertTrue(view.string.contains("rv-a1b2"), "comments stay")
    }

    func testLeavingAReplyFieldDoesNotSendIt() {
        makeView(width: 1500)
        view.load(Self.doc)
        let field = view.reviewCards[0].replyField
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        XCTAssertNotNil(field.currentEditor(), "editing, as when typed into")
        type("half a tho", into: field)
        window.makeFirstResponder(view)
        XCTAssertFalse(view.string.contains("half a tho"))
    }

    // MARK: Review fixes

    func testTypingKeepsTheCardsAndAHalfWrittenReply() {
        makeView(width: 1500)
        view.load(Self.doc)
        let before = view.reviewCards
        before[1].replyField.stringValue = "half a tho"
        view.isEditable = true
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())
        XCTAssertEqual(view.reviewCards.count, 3)
        for (a, b) in zip(before, view.reviewCards) { XCTAssertTrue(a === b, "card \(a.id) kept") }
        XCTAssertEqual(view.reviewCards[1].replyField.stringValue, "half a tho")
        // Still beside their anchors, which moved down with the edit? Same line here; but they follow:
        let lm = view.layoutManager!
        let line = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: ns.range(of: "cache").location),
                                       effectiveRange: nil)
        XCTAssertEqual(view.reviewCards[0].frame.minY, line.minY + view.textContainerOrigin.y, accuracy: 1)
    }

    func testCardsFollowTheTheme() {
        makeView(width: 1500)
        view.load(Self.doc)
        view.theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16,
                                 measure: 70, fullWidth: false, dark: true)
        XCTAssertEqual(view.reviewCards.first?.layer?.backgroundColor, view.theme.paperDeep.cgColor)
    }

    func testAComposerRefusesTextThatChangedUnderIt() {
        makeView(width: 1500)
        window.orderFront(nil)
        view.load("The cache is cold.\n")
        view.setSelectedRange(ns.range(of: "cold"))
        view.addReviewComment(nil)
        let composer = view.reviewComposer!
        view.isEditable = true
        view.insertText("Hot: ", replacementRange: NSRange(location: 0, length: 0))   // an edit while it is open
        type("Why?", into: composer.bodyField)
        composer.submit()
        XCTAssertEqual(view.string, "Hot: The cache is cold.\n")
        XCTAssertTrue(composer.messageLabel.stringValue.contains("changed"))
    }

    func testReloadingTheDocumentClosesTheComposer() {
        makeView(width: 1500)
        window.orderFront(nil)
        view.load("The cache is cold.\n")
        view.setSelectedRange(ns.range(of: "cold"))
        view.addReviewComment(nil)
        view.load("Completely different words now.\n")
        XCTAssertNotEqual(view.reviewComposerPopover?.isShown, true)
    }

    func testCommentingFromATableCellIsRefusedNotMisplaced() {
        makeView(width: 1500)
        window.makeKeyAndOrderFront(nil)
        view.load("Before.\n\n| a | b |\n|---|---|\n| c | d |\n")
        view.setSelectedRange(ns.range(of: "Before"))   // an old selection in the main text
        window.makeFirstResponder(view.tableGrids[0].cell(row: 1, column: 0))
        view.addReviewComment(nil)
        XCTAssertNil(view.reviewComposer, "no composer for the main text's old selection")
    }
}
