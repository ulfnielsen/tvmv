import AppKit
import XCTest
@testable import tvmv

/// Adding or settling a comment keeps the page where it was.
@MainActor
final class ReviewScrollTests: XCTestCase {
    private var window: NSWindow!
    private var view: DocumentTextView!

    private func makeView(width: CGFloat = 1500) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.hasVerticalScroller = true
        view = DocumentTextView.make()
        view.theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16,
                                 measure: 70, fullWidth: false, dark: false)
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = view
        window.contentView!.addSubview(scroll)
    }

    private var ns: NSString { view.string as NSString }
    private var scroll: NSScrollView { view.enclosingScrollView! }

    /// Where `word`'s line sits relative to the top of the visible page.
    private func onScreen(_ word: String) -> CGFloat {
        let lm = view.layoutManager!
        let glyph = lm.glyphIndexForCharacter(at: ns.range(of: word).location)
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.minY + view.textContainerOrigin.y - scroll.documentVisibleRect.minY
    }

    private func body(_ n: Int) -> String {
        (0..<n).map { "Paragraph \($0) of the body, long enough to read like prose in a document." }
            .joined(separator: "\n\n") + "\n\n"
    }

    /// Scroll so `word` sits 300 points below the top of the window.
    private func scroll(toShow word: String) {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        let glyph = lm.glyphIndexForCharacter(at: ns.range(of: word).location)
        let y = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + view.textContainerOrigin.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y - 300))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func check(_ what: String, word: String, file: StaticString = #filePath, line: UInt = #line,
                       _ action: () -> Void) {
        let before = onScreen(word)
        action()
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        XCTAssertEqual(onScreen(word), before, accuracy: 1, "\(what): the page moved", file: file, line: line)
    }

    func testTheFirstCommentKeepsThePage() {
        makeView()
        view.load(body(80))
        scroll(toShow: "Paragraph 40 ")
        view.setSelectedRange(ns.range(of: "Paragraph 41"))
        check("first comment", word: "Paragraph 40 ") {
            view.addComment(body: "Why?", author: "ulf")
        }
    }

    func testAnotherCommentKeepsThePage() {
        makeView()
        view.load("Top {==x==}[^rv-a1b2].\n\n" + body(80) + "[^rv-a1b2]: @ulf 2026-10-14: One.\n")
        scroll(toShow: "Paragraph 40 ")
        view.setSelectedRange(ns.range(of: "Paragraph 41"))
        check("another comment", word: "Paragraph 40 ") {
            view.addComment(body: "Why?", author: "ulf")
        }
    }

    func testResolvingKeepsThePage() {
        makeView()
        view.load("Top {==x==}[^rv-a1b2].\n\n" + body(40) + "Mid {==y==}[^rv-c3d4].\n\n" + body(40)
                  + "[^rv-a1b2]: @ulf 2026-10-14: One.\n[^rv-c3d4]: @ulf 2026-10-14: Two.\n")
        scroll(toShow: "Mid ")
        view.setSelectedRange(NSRange(location: ns.range(of: "y==").location, length: 0))
        check("resolve", word: "Mid ") { view.settle("rv-c3d4", .resolve) }
    }

    func testResolvingTheLastThreadKeepsThePage() {
        makeView()
        view.load(body(40) + "Mid {==y==}[^rv-c3d4].\n\n" + body(40) + "[^rv-c3d4]: @ulf 2026-10-14: Two.\n")
        scroll(toShow: "Mid ")
        view.setSelectedRange(NSRange(location: ns.range(of: "y==").location, length: 0))
        check("resolve last", word: "Mid ") { view.settle("rv-c3d4", .resolve) }
    }

    private func comment(_ word: String, first: Bool, width: CGFloat = 1500) {
        makeView(width: width)
        window.orderFront(nil)
        view.load((first ? "" : "Top {==x==}[^rv-a1b2].\n\n") + body(80)
                  + (first ? "" : "[^rv-a1b2]: @ulf 2026-10-14: One.\n"))
        scroll(toShow: "Paragraph 40 ")
        view.setSelectedRange(ns.range(of: word))
        check(first ? "first comment" : "another comment", word: word) {
            view.addReviewComment(nil)
            let composer = view.reviewComposer!
            if let editor = composer.bodyField.currentEditor() as? NSTextView { editor.string = "Why?" }
            else { composer.bodyField.stringValue = "Why?" }
            composer.submit()
        }
        XCTAssertEqual(view.reviewCards.count, first ? 1 : 2)
    }

    func testCommentingThroughTheComposerKeepsThePage() { comment("Paragraph 41", first: false) }
    func testTheFirstCommentThroughTheComposerKeepsThePage() { comment("Paragraph 41", first: true) }

    // A window too narrow for the text and the column: the text narrows.
    func testTheFirstCommentInANarrowWindowKeepsThePage() { comment("Paragraph 41", first: true, width: 900) }
    func testCommentingInANarrowWindowKeepsThePage() { comment("Paragraph 41", first: false, width: 900) }

    func testResolvingTheLastThreadInANarrowWindowKeepsThePage() {
        makeView(width: 900)
        view.load(body(40) + "Mid {==y==}[^rv-c3d4].\n\n" + body(40) + "[^rv-c3d4]: @ulf 2026-10-14: Two.\n")
        scroll(toShow: "Mid ")
        view.setSelectedRange(NSRange(location: ns.range(of: "y==").location, length: 0))
        check("resolve last, narrow", word: "Mid ") { view.settle("rv-c3d4", .resolve) }
    }
}
