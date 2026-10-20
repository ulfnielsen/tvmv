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
}
