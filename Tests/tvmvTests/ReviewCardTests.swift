import XCTest
import AppKit
import TVMVCore
@testable import tvmv

@MainActor
final class ReviewCardTests: XCTestCase {
    private var window: NSWindow!
    private var view: DocumentTextView!

    private func makeView(width: CGFloat, fullWidth: Bool = false, scroller: Bool = false) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.hasVerticalScroller = scroller   // as the app's: it appears when the page outgrows the window
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

    func testANarrowWindowMakesRoomForTheCardsBesideTheText() {
        // Comments live on the side, never in popovers: a full-width or narrow
        // window narrows the text column to fit the card column.
        makeView(width: 800, fullWidth: true)
        view.load("Plain text with no comments at all, long enough to wrap the line.\n")
        let plainColumn = view.textContainer!.size.width
        view.load(Self.doc)
        XCTAssertEqual(view.reviewCards.count, 3)
        let columnRight = view.textContainerOrigin.x + view.textContainer!.size.width
        XCTAssertLessThan(view.textContainer!.size.width, plainColumn)
        for card in view.reviewCards {
            XCTAssertGreaterThan(card.frame.minX, columnRight)
            XCTAssertLessThanOrEqual(card.frame.maxX, view.bounds.width)
            XCTAssertGreaterThanOrEqual(card.frame.width, 200)
        }
    }

    func testTheColumnComesBackWhenTheLastCommentGoes() {
        makeView(width: 800, fullWidth: true)
        view.load("Plain text with no comments.\n")
        let plainColumn = view.textContainer!.size.width
        view.load("A {==b==}[^rv-a1b2] c.\n\n[^rv-a1b2]: @ulf 2026-10-14: x\n")
        XCTAssertLessThan(view.textContainer!.size.width, plainColumn)
        view.settle("rv-a1b2", .resolve)
        XCTAssertEqual(view.textContainer!.size.width, plainColumn)
        XCTAssertTrue(view.reviewCards.isEmpty)
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
        XCTAssertTrue(composer.superview === view, "written in the side column, not a popover")
        let columnRight = view.textContainerOrigin.x + view.textContainer!.size.width
        XCTAssertGreaterThan(composer.frame.minX, columnRight)
        let lm = view.layoutManager!
        let line = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: ns.range(of: "cache").location),
                                       effectiveRange: nil)
        XCTAssertEqual(composer.frame.minY, line.minY + view.textContainerOrigin.y, accuracy: 1, "beside the selection")
        XCTAssertNil(composer.replacementField, "a comment has no replacement")
        type("Why?", into: composer.bodyField)
        composer.submit()
        XCTAssertTrue(view.string.hasPrefix("The {==cache==}[^rv-"))
        XCTAssertTrue(view.string.contains(": Why?\n"))
        XCTAssertNil(view.reviewComposer?.superview, "closed once added")
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
        XCTAssertNil(view.reviewComposer?.superview)
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

    func testTheContextMenuOffersCommentAndSuggestEdit() {
        makeView(width: 1500)
        view.load("The cache is cold.\n")
        view.setSelectedRange(ns.range(of: "cache"))
        let point = view.convert(NSPoint(x: view.textContainerOrigin.x + 30, y: view.textContainerOrigin.y + 10), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)!
        let menu = view.menu(for: event)!
        let titles = menu.items.map(\.title)
        XCTAssertEqual(Array(titles.prefix(2)), ["Comment…", "Suggest Edit…"])
        XCTAssertEqual(menu.items[0].action, #selector(DocumentTextView.addReviewComment(_:)))
        XCTAssertEqual(menu.items[1].action, #selector(DocumentTextView.suggestReviewEdit(_:)))
    }

    // MARK: Compact cards

    private func lineTop(of word: String) -> CGFloat {
        let lm = view.layoutManager!
        let line = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: ns.range(of: word).location),
                                       effectiveRange: nil)
        return line.minY + view.textContainerOrigin.y
    }

    func testOnlyTheFocusedCardShowsItsActions() {
        makeView(width: 1500)
        view.load(Self.doc)
        XCTAssertTrue(view.reviewCards.allSatisfy { $0.replyField.isHiddenOrHasHiddenAncestor })
        let compact = view.reviewCards[1].frame.height
        view.setSelectedRange(NSRange(location: ns.range(of: "cold").location + 1, length: 0))
        XCTAssertFalse(view.reviewCards[1].replyField.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(view.reviewCards[1].button("Accept")!.isHiddenOrHasHiddenAncestor)
        XCTAssertGreaterThan(view.reviewCards[1].frame.height, compact)
    }

    func testTheFocusedCardSitsOnItsLineAndTheOthersMakeWay() {
        makeView(width: 1500)
        // Three comments on one line: stacked, the third would sit far below it.
        // (Room above for the cards that make way.)
        let text = String(repeating: "Filler paragraph to leave room above.\n\n", count: 12) + "A {==b==}[^rv-a1b2] {==c==}[^rv-c3d4] {==d==}[^rv-e5f6].\n\n"
            + "[^rv-a1b2]: @ulf 2026-10-14: One.\n[^rv-c3d4]: @ulf 2026-10-14: Two.\n[^rv-e5f6]: @ulf 2026-10-14: Three.\n"
        view.load(text)
        view.setSelectedRange(NSRange(location: ns.range(of: "d==").location, length: 0))
        let cards = view.reviewCards
        XCTAssertEqual(cards[2].frame.minY, lineTop(of: "d=="), accuracy: 1, "the focused card on its line")
        XCTAssertLessThanOrEqual(cards[1].frame.maxY, cards[2].frame.minY)
        XCTAssertLessThanOrEqual(cards[0].frame.maxY, cards[1].frame.minY)
    }

    func testClickingACardFocusesIt() {
        makeView(width: 1500)
        view.load(Self.doc)
        view.reviewCards[2].mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        XCTAssertEqual(view.reviewCards.filter(\.isFocused).map(\.id), ["rv-e5f6"])
        XCTAssertFalse(view.reviewCards[2].replyField.isHiddenOrHasHiddenAncestor)
    }

    func testTheComposerSitsOnItsLine() {
        makeView(width: 1500)
        window.orderFront(nil)
        view.load(Self.doc + "\n" + String(repeating: "Filler paragraph to leave room above.\n\n", count: 12) + "Last line.\n")
        view.setSelectedRange(ns.range(of: "Last"))
        view.addReviewComment(nil)
        XCTAssertEqual(view.reviewComposer!.frame.minY, lineTop(of: "Last"), accuracy: 1)
    }

    func testCardsAtTheEndStayInsideTheDocument() {
        makeView(width: 1500)
        // Comments on the last line: their cards hang below the text.
        var text = String(repeating: "Body paragraph.\n\n", count: 30) + "End {==a==}[^rv-a1b2] {==b==}[^rv-c3d4].\n\n"
        text += "[^rv-a1b2]: @ulf 2026-10-14: One.\n[^rv-c3d4]: @ulf 2026-10-14: Two, with a longer note that wraps over lines.\n"
        view.load(text)
        let scroll = view.enclosingScrollView!
        // Scrolled so the compact last card just shows at the bottom of the window.
        let compact = view.reviewCards[1].frame
        scroll.contentView.scroll(to: NSPoint(x: 0, y: compact.maxY - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        view.setSelectedRange(NSRange(location: ns.range(of: "b==").location, length: 0))
        let focused = view.reviewCards[1]
        XCTAssertTrue(focused.isFocused)
        XCTAssertGreaterThan(focused.frame.height, compact.height, "it grew with its actions")
        XCTAssertGreaterThanOrEqual(view.frame.height, focused.frame.maxY, "the document holds it")
        XCTAssertTrue(scroll.documentVisibleRect.insetBy(dx: 0, dy: -1).contains(focused.frame),
                      "the focused card scrolled into view: \(focused.frame) in \(scroll.documentVisibleRect)")
    }

    func testAFocusedCardNearTheWindowBottomScrollsIntoView() {
        makeView(width: 1500)
        var text = String(repeating: "Body paragraph.\n\n", count: 60) + "Here {==a==}[^rv-a1b2] is one.\n\n"
        text += String(repeating: "Tail paragraph.\n\n", count: 30)
        text += "[^rv-a1b2]: @ulf 2026-10-14: A note long enough to wrap onto a second line in the card.\n"
        view.load(text)
        let scroll = view.enclosingScrollView!
        // The anchor's line just inside the bottom of the window.
        let line = lineTop(of: "a==")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: line + 30 - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        view.setSelectedRange(NSRange(location: ns.range(of: "a==").location, length: 0))
        let card = view.reviewCards[0]
        XCTAssertTrue(card.isFocused)
        XCTAssertTrue(scroll.documentVisibleRect.insetBy(dx: 0, dy: -1).contains(card.frame),
                      "\(card.frame) in \(scroll.documentVisibleRect)")
    }

    func testAComposerThatGrowsKeepsTheColumnLaidOut() {
        makeView(width: 1500)
        window.orderFront(nil)
        view.load("One.\n\nTwo.\n")
        view.setSelectedRange(NSRange(location: 0, length: ns.length))
        view.addReviewComment(nil)
        let composer = view.reviewComposer!
        type("x", into: composer.bodyField)
        composer.submit()   // refused: the message makes it taller
        XCTAssertGreaterThanOrEqual(view.frame.height, composer.frame.maxY + view.textContainerInset.height - 1)
    }

    func testThreadsWithRepliesAtTheEndOfAShortDocumentFitInIt() {
        // Reported: several comments at the end, with replies, ran off the
        // page. The cards outgrow a document shorter than the window, and the
        // scroll view's own sizing reset the text view's minimum height.
        makeView(width: 1400, scroller: true)
        var text = "Body paragraph.\n\n", defs = ""
        for i in 0..<5 {
            let id = "rv-e\(i)00"
            text += "Last part {==word \(i)==}[^\(id)] here.\n\n"
            defs += "[^\(id)]: @ulf 2026-10-14: Comment \(i) that is long enough to wrap in the card.\n"
            for r in 0..<3 { defs += "    @claude 2026-10-14: Reply \(r) to comment \(i), also wrapping onto lines.\n" }
        }
        view.load(text + defs)
        let last = view.reviewCards.map(\.frame.maxY).max()!
        XCTAssertGreaterThan(last, view.enclosingScrollView!.contentSize.height, "the cards outgrow the window")
        XCTAssertGreaterThanOrEqual(view.frame.height, last, "the page holds every card")
        for i in 0..<5 { view.settle("rv-e\(i)00", .resolve) }
        XCTAssertLessThan(view.frame.height, last, "and shrinks back once they're resolved")
    }
}
