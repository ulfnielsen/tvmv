import XCTest
import AppKit
import TVMVCore
@testable import tvmv

@MainActor
final class NativeDocumentViewTests: XCTestCase {
    private let theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16,
                                    measure: 80, fullWidth: false, dark: false)

    func testScrollViewStartsWithTheTextViewSizedToItsClipView() {
        // Regression: SwiftUI hosts the scroll view with Auto Layout, which
        // turns the text view's autoresizing mask into constraints. A
        // mismatch between the text view and its clip view at creation
        // became a permanent surplus — in the app an 800 pt placeholder made
        // the text view 1819 pt in a 1019 pt clip view, centering the column
        // off-screen. Created at the clip view's size, there is no surplus.
        let (scroll, view) = NativeDocumentView.makeScrollView(theme: theme)
        XCTAssertEqual(view.frame.width, scroll.contentSize.width)
    }

    func testOutlineUsesTheWebReadersSlugs() {
        let layout = MarkdownLayoutParser.parse("# Intro\n\n## Setup *fast*\n\n## Setup fast\n")
        XCTAssertEqual(NativeDocumentController.outline(from: layout), [
            OutlineItem(level: 1, title: "Intro", anchor: "intro"),
            OutlineItem(level: 2, title: "Setup fast", anchor: "setup-fast"),
            OutlineItem(level: 2, title: "Setup fast", anchor: "setup-fast-1"),
        ])
    }

    func testScrollToOffsetAndAnchorRoundTrip() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let (scroll, view) = NativeDocumentView.makeScrollView(theme: theme)
        scroll.frame = window.contentView!.bounds
        window.contentView!.addSubview(scroll)
        let controller = NativeDocumentController()
        controller.attach(view)
        var text = ""
        for i in 1...60 {
            if i == 40 { text += "## Far Away\n\n" }   // mid-document, so it can scroll to the top
            text += "Paragraph \(i) with enough words to wrap a little.\n\n"
        }
        view.load(text)
        view.layoutManager!.ensureLayout(for: view.textContainer!)

        let target = (text as NSString).range(of: "Paragraph 30").location
        controller.scrollTo(offset: target)
        XCTAssertEqual(controller.topVisibleOffset(), target, accuracy: 2)
        XCTAssertGreaterThan(controller.progress, 0)

        controller.scrollTo(anchor: "far-away")
        let heading = (text as NSString).range(of: "## Far Away").location
        XCTAssertLessThanOrEqual(abs(controller.topVisibleOffset() - heading), 3)
    }

    func testLinkPolicyOpensOnlyWebMailAndMarkdownTargets() {
        // Regression (security review): the native view must not open
        // arbitrary schemes or files from a document's links. The web reader
        // handed only http/https/mailto to the system; keep that, and allow
        // relative links only to Markdown documents.
        let doc = URL(fileURLWithPath: "/docs/guide/readme.md")
        typealias Target = NativeDocumentController.LinkTarget
        func target(_ link: String) -> Target { NativeDocumentController.linkTarget(link, documentURL: doc) }

        XCTAssertEqual(target("#setup"), .anchor("setup"))
        XCTAssertEqual(target("#caf%C3%A9"), .anchor("café"))
        XCTAssertEqual(target("https://example.com/x"), .external(URL(string: "https://example.com/x")!))
        XCTAssertEqual(target("HTTP://example.com"), .external(URL(string: "HTTP://example.com")!))
        XCTAssertEqual(target("mailto:a@b.c"), .external(URL(string: "mailto:a@b.c")!))
        XCTAssertEqual(target("other.md"), .document(URL(fileURLWithPath: "/docs/guide/other.md")))
        XCTAssertEqual(target("../notes%20x.markdown#top"), .document(URL(fileURLWithPath: "/docs/notes x.markdown")))

        XCTAssertEqual(target("file:///Applications/Calculator.app"), .blocked)
        XCTAssertEqual(target("x-apple.systempreferences:com.apple.preference.security"), .blocked)
        XCTAssertEqual(target("javascript:alert(1)"), .blocked)
        XCTAssertEqual(target("ssh://host"), .blocked)
        XCTAssertEqual(target("run.command"), .blocked)
        XCTAssertEqual(target("../Evil.app"), .blocked)
        XCTAssertEqual(target("/etc/hosts"), .blocked)
        XCTAssertEqual(NativeDocumentController.linkTarget("other.md", documentURL: nil), .blocked)
    }
}
