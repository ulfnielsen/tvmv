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

    func testLinkPolicyOpensOnlyWebMailAndMarkdownTargets() throws {
        // Regression (security review): the native view must not open
        // arbitrary schemes or files from a document's links. The web reader
        // handed only http/https/mailto to the system; keep that, and allow
        // relative links only to Markdown documents that really are files.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tvmv-links-\(UUID().uuidString)")
        let guide = root.appendingPathComponent("guide")
        try fm.createDirectory(at: guide, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: root) }
        try "x".write(to: guide.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("notes x.markdown"), atomically: true, encoding: .utf8)
        // A "Markdown" name that is really an app, and one that is a folder.
        try fm.createSymbolicLink(at: guide.appendingPathComponent("trap.md"),
                                  withDestinationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        try fm.createDirectory(at: guide.appendingPathComponent("folder.md"), withIntermediateDirectories: true)

        let doc = guide.appendingPathComponent("readme.md")
        typealias Target = NativeDocumentController.LinkTarget
        func target(_ link: String) -> Target { NativeDocumentController.linkTarget(link, documentURL: doc) }
        func resolved(_ url: URL) -> URL { url.resolvingSymlinksInPath() }

        XCTAssertEqual(target("#setup"), .anchor("setup"))
        XCTAssertEqual(target("#caf%C3%A9"), .anchor("café"))
        XCTAssertEqual(target("https://example.com/x"), .external(URL(string: "https://example.com/x")!))
        XCTAssertEqual(target("HTTP://example.com"), .external(URL(string: "HTTP://example.com")!))
        XCTAssertEqual(target("mailto:a@b.c"), .external(URL(string: "mailto:a@b.c")!))
        XCTAssertEqual(target("other.md"), .document(resolved(guide.appendingPathComponent("other.md"))))
        XCTAssertEqual(target("../notes%20x.markdown#top"), .document(resolved(root.appendingPathComponent("notes x.markdown"))))

        XCTAssertEqual(target("trap.md"), .blocked, "a symlink to an app")
        XCTAssertEqual(target("folder.md"), .blocked, "a directory")
        XCTAssertEqual(target("missing.md"), .blocked)
        XCTAssertEqual(target("file:///System/Applications/Calculator.app"), .blocked)
        XCTAssertEqual(target("x-apple.systempreferences:com.apple.preference.security"), .blocked)
        XCTAssertEqual(target("javascript:alert(1)"), .blocked)
        XCTAssertEqual(target("ssh://host"), .blocked)
        XCTAssertEqual(target("run.command"), .blocked)
        XCTAssertEqual(target("../Evil.app"), .blocked)
        XCTAssertEqual(target("/etc/hosts"), .blocked)
        XCTAssertEqual(NativeDocumentController.linkTarget("other.md", documentURL: nil), .blocked)
    }

    func testRestoringBeforeTheViewIsSizedLandsOnTheSavedPlace() {
        // Final review: makeNSView restores the reading position before
        // SwiftUI has given the scroll view its size, when the column is
        // only 200 pt wide; the offset's y there is wrong after reflow.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let (scroll, view) = NativeDocumentView.makeScrollView(theme: theme)
        let controller = NativeDocumentController()
        controller.attach(view)
        var text = ""
        for i in 1...80 { text += "Paragraph \(i) with enough words that it wraps when the column is narrow.\n\n" }
        view.load(text)
        let target = (text as NSString).range(of: "Paragraph 40").location

        controller.restoreWhenSized(.offset(target))       // not sized yet
        window.contentView!.addSubview(scroll)
        scroll.frame = window.contentView!.bounds           // now SwiftUI sizes it
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        XCTAssertEqual(controller.topVisibleOffset(), target, accuracy: 2)
    }

    func testReviewMenuCommandsReachTheTextView() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let (scroll, view) = NativeDocumentView.makeScrollView(theme: theme)
        scroll.frame = window.contentView!.bounds
        window.contentView!.addSubview(scroll)
        let controller = NativeDocumentController()
        controller.attach(view)
        view.load("A {++b++}[^rv-a1b2] c.\n\n[^rv-a1b2]: @ulf 2026-10-14 suggestion: x\n")
        controller.review(.nextThread)
        XCTAssertEqual(view.selectedRange().location, (view.string as NSString).range(of: "b++").location)
        controller.review(.acceptAll)
        XCTAssertEqual(view.string, "A b c.\n")
    }
}
