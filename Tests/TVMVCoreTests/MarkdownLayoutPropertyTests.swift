import XCTest
@testable import TVMVCore

/// Random edits over the showcase fixture. Every full parse must hide only
/// markup, and `changedRange` must cover every styling difference between
/// consecutive parses (it bounds the restyle, so a miss is a stale style).
final class MarkdownLayoutPropertyTests: XCTestCase {
    private struct LCG {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(bound, 1)))
        }
    }

    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/showcase.md")

    private static let tokens = [
        "*", "**", "_", "`", "``", "```\n", "~~", "# ", "## ", "\n", "\n\n", "x", "word ", "[a](b)",
        "[r]", "[r]: http://z\n", "- ", "> ", "| a |", "\\\n", "  \n", "==\n", "<http://q>", "é", "😀",
        " ", "1. ", "<div>\n", " ##", "www.q.com ",
    ]

    func testRandomEditsKeepInvariantsAndDiffsSound() throws {
        let start = try String(contentsOf: Self.fixture, encoding: .utf8)
        for seed: UInt64 in [1, 2, 3] {
            var rng = LCG(state: seed)
            var text = start
            var layout = MarkdownLayoutParser.parse(text)
            for step in 0..<600 {
                let ns = text as NSString
                var location = rng.next(ns.length + 1)
                var length = rng.next(3) == 0 ? rng.next(min(8, ns.length - location) + 1) : 0
                // Never split a surrogate pair.
                if location > 0, location < ns.length, UTF16.isTrailSurrogate(ns.character(at: location)) {
                    location -= 1; length = 0
                }
                if length > 0, location + length < ns.length,
                   UTF16.isTrailSurrogate(ns.character(at: location + length)) { length += 1 }
                let insert = rng.next(4) == 0 ? "" : Self.tokens[rng.next(Self.tokens.count)]
                let edit = NSRange(location: location, length: min(length, ns.length - location))
                let newText = ns.replacingCharacters(in: edit, with: insert)
                let delta = (insert as NSString).length - edit.length
                let new = MarkdownLayoutParser.parse(newText)

                let context = "seed \(seed) step \(step) edit \(edit) «\(insert)»"
                assertInvariants(new, newText, context)
                assertDiffSound(old: layout, new: new, edit: edit, delta: delta, context)
                text = newText
                layout = new
            }
        }
    }

    private func assertInvariants(_ layout: MarkdownLayout, _ text: String, _ context: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let ns = text as NSString
        var claimed = IndexSet()
        for marker in layout.markers {
            XCTAssertTrue(NSMaxRange(marker.range) <= ns.length, "out of bounds: \(context)", file: file, line: line)
            XCTAssertTrue(marker.unit.encloses(marker.range), "marker outside its unit: \(context)", file: file, line: line)
            let hiddenText = ns.substring(with: marker.range)
            let isMarkup = marker.collapsesLine
                ? hiddenText.contains("```") || hiddenText.contains("~~~")
                    || hiddenText.allSatisfy { "=-\n \t".contains($0) }
                : hiddenText.allSatisfy { "*_`~#[]<> \t".contains($0) }
                    || hiddenText.hasPrefix("](") || hiddenText.hasPrefix("][")
            XCTAssertTrue(isMarkup, "hides non-markup «\(hiddenText)»: \(context)", file: file, line: line)
            let span = marker.range.location..<NSMaxRange(marker.range)
            XCTAssertFalse(claimed.intersects(integersIn: span), "overlapping markers: \(context)", file: file, line: line)
            claimed.insert(integersIn: span)
        }
    }

    /// Outside `changed`, the new layout's styles and markers must equal the
    /// old ones (shifted past the edit). Old entries inside the edited text
    /// went away with it.
    private func assertDiffSound(old: MarkdownLayout, new: MarkdownLayout, edit: NSRange, delta: Int,
                                 _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let changed = new.changedRange(from: old, edit: edit, delta: delta)
        func outside(_ r: NSRange) -> Bool { NSMaxRange(r) <= changed.location || r.location >= NSMaxRange(changed) }
        func survived(_ r: NSRange) -> Bool { r.location < edit.location || r.location >= NSMaxRange(edit) }
        func shift(_ r: NSRange) -> NSRange { r.location >= NSMaxRange(edit) ? r.shifted(by: delta) : r }

        let newStyles = new.styles.filter { outside($0.range) }
        let oldStyles = old.styles.filter { survived($0.range) }
            .map { MarkdownLayout.StyleRun(range: shift($0.range), style: $0.style) }
            .filter { outside($0.range) }
        XCTAssertEqual(newStyles, oldStyles, "styles changed outside \(changed): \(context)", file: file, line: line)

        let newMarkers = new.markers.filter { outside($0.unit) }
        let oldMarkers = old.markers.filter { survived($0.unit) }
            .map { MarkdownLayout.Marker(range: shift($0.range), unit: shift($0.unit), collapsesLine: $0.collapsesLine) }
            .filter { outside($0.unit) }
        XCTAssertEqual(newMarkers, oldMarkers, "markers changed outside \(changed): \(context)", file: file, line: line)
    }
}
