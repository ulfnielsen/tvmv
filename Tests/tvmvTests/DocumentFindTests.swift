import AppKit
import XCTest
import TVMVNativeText
@testable import tvmv

@MainActor
final class DocumentFindTests: XCTestCase {
    private let theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16,
                                    measure: 80, fullWidth: false, dark: false)

    func testFindNavigatesBetweenRenderedCellAndBody() throws {
        let (window, scroll, view) = makeDocument("Intro\n\n| A | B |\n| --- | --- |\n| alpha **beta** | other |\n\nalpha beta below\n")
        defer { window.orderOut(nil) }
        let cell = try XCTUnwrap(view.tableGrids.first?.cells.last?.first)
        let body = (view.string as NSString).range(of: "alpha beta")
        XCTAssertTrue(window.makeFirstResponder(cell))
        action(.showFindInterface, in: cell)
        XCTAssertTrue(scroll.isFindBarVisible)
        XCTAssertTrue(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        try query("alpha beta", in: scroll)
        action(.nextMatch, in: view)
        XCTAssertEqual(cell.selectedRange(), NSRange(location: 0, length: 12))
        action(.nextMatch, in: view)
        XCTAssertEqual(view.selectedRange(), body)
        action(.nextMatch, in: view)
        XCTAssertEqual(cell.selectedRange(), NSRange(location: 0, length: 12))
    }

    func testFindSkipsTableSyntaxAndRefreshesAfterChanges() throws {
        let (window, scroll, view) = makeDocument("Intro\n\n| A | B |\n| --- | --- |\n| left | right |\n")
        defer { window.orderOut(nil) }
        let cell = try XCTUnwrap(view.tableGrids.first?.cells.last?.first)
        action(.showFindInterface, in: view)
        let start = NSRange(location: 0, length: 0)
        view.setSelectedRange(start)
        cell.setSelectedRange(start)
        for s in ["|", "leftright"] {
            try query(s, in: scroll)
            action(.nextMatch, in: view)
            XCTAssertEqual(view.selectedRange(), start, s)
            XCTAssertEqual(cell.selectedRange(), start, s)
        }
        view.isEditable = true
        XCTAssertTrue(cell.replace(NSRange(location: 0, length: 4), with: "fresh"))
        try query("fresh", in: scroll)
        action(.nextMatch, in: view)
        XCTAssertEqual(cell.selectedRange(), NSRange(location: 0, length: 5))
        view.showAllMarkup = true
        try query("|", in: scroll)
        action(.nextMatch, in: view)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 7, length: 1))
    }

    func testIncrementalFindCanOutliveClosingItsDocument() throws {
        try autoreleasepool {
            let (window, scroll, view) = makeDocument("| A |\n| --- |\n| needle |\n")
            action(.showFindInterface, in: view)
            try query("needle", in: scroll)
            window.orderOut(nil)
            scroll.removeFromSuperview()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    private func makeDocument(_ text: String) -> (NSWindow, NSScrollView, DocumentTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let (scroll, view) = NativeDocumentView.makeScrollView(theme: theme)
        scroll.frame = window.contentView!.bounds
        window.contentView!.addSubview(scroll)
        view.load(text)
        return (window, scroll, view)
    }

    private func action(_ action: NSTextFinder.Action, in view: DocumentTextView) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        view.performTextFinderAction(item)
    }

    private func query(_ text: String, in scroll: NSScrollView) throws {
        func searchField(in view: NSView) -> NSSearchField? {
            (view as? NSSearchField) ?? view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let root = try XCTUnwrap(scroll.findBarView)
        let field = try XCTUnwrap(searchField(in: root))
        if let editor = field.currentEditor() {
            editor.selectAll(nil)
            editor.insertText(text)
        } else {
            field.stringValue = text
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        }
    }
}
