import XCTest
import TVMVCore
@testable import TVMVNativeText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class MarkdownTextEngineTests: XCTestCase {
    /// Records what the engine tells its host.
    private final class FakeHost: MarkdownTextHost {
        var hasMarkedText = false
        var restyled: [NSRange] = []
        var applied: [MarkdownLayout] = []

        func engine(_ engine: MarkdownTextEngine, didRestyle range: NSRange) { restyled.append(range) }
        func engine(_ engine: MarkdownTextEngine, didApply layout: MarkdownLayout) { applied.append(layout) }
    }

    private var storage: NSTextStorage!
    private var host: FakeHost!
    private var engine: MarkdownTextEngine!

    override func setUp() {
        storage = NSTextStorage()
        host = FakeHost()
        engine = MarkdownTextEngine(storage: storage, host: host)
    }

    /// Replace `range` the way a text view's storage delegate reports it.
    private func edit(_ range: NSRange, _ string: String) {
        storage.replaceCharacters(in: range, with: string)
        let delta = (string as NSString).length - range.length
        engine.recordEdit(editedRange: NSRange(location: range.location, length: (string as NSString).length),
                          delta: delta)
        engine.textChanged()
    }

    private func hidden(_ index: Int) -> Bool {
        storage.attribute(.tvmvHidden, at: index, effectiveRange: nil) != nil
    }

    func testSmallEditParsesSynchronously() {
        engine.load("a *b* c")
        host.applied = []
        edit(NSRange(location: 0, length: 0), "x")
        XCTAssertEqual(host.applied.count, 1, "applied before textChanged returned")
        XCTAssertEqual(engine.layout.length, 8)
    }

    func testLargeDocumentParsesInBackgroundLatestWins() {
        let line = "Some *emphasis* and **strong** text in a paragraph.\n\n"
        let text = String(repeating: line, count: 70 * 1024 / line.utf16.count + 1)
        XCTAssertGreaterThan(text.utf16.count, MarkdownTextEngine.syncParseLimit)
        engine.load(text)
        edit(NSRange(location: 0, length: 0), "x")
        edit(NSRange(location: 1, length: 0), "y")
        XCTAssertEqual(engine.backgroundParsesStarted, 1)
        let deadline = Date().addingTimeInterval(5)
        while engine.layout.length != storage.length, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(engine.layout.length, storage.length)
        XCTAssertEqual(engine.layout, MarkdownLayoutParser.parse(storage.string))
    }

    func testMarkedTextBlocksApply() {
        engine.load("a *b* c")
        host.applied = []
        host.hasMarkedText = true
        edit(NSRange(location: 0, length: 0), "x")
        XCTAssertTrue(host.applied.isEmpty)
        host.hasMarkedText = false
        engine.textChanged()
        XCTAssertEqual(host.applied.count, 1)
        XCTAssertEqual(engine.layout.length, storage.length)
    }

    func testRevealRestylesTouchedRange() {
        engine.load("a **b** c")
        XCTAssertTrue(hidden(2))
        XCTAssertTrue(hidden(6))
        let unit = engine.units(enclosing: NSRange(location: 4, length: 0)).first!
        XCTAssertEqual(unit, NSRange(location: 2, length: 5))
        host.restyled = []
        engine.setRevealedUnits([unit])
        XCTAssertTrue(engine.isRevealed(unit))
        XCTAssertTrue(host.restyled.contains { NSIntersectionRange($0, unit) == unit })
        for i in [2, 3, 5, 6] { XCTAssertFalse(hidden(i), "star at \(i)") }
    }
}
