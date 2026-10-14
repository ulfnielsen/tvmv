# Native Editor — Core and View (Plan 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the macOS split pane (CodeMirror + WKWebView preview) with one native TextKit 1 view that reads and edits Markdown in place with its markup hidden, plus the reader features (outline, links, reading position, bookmarks, find, print, settings).

**Architecture:** A pure `TVMVCore` layer parses the text with the pinned cmark-gfm into a `MarkdownLayout` (style runs, hidden "markers" grouped into reveal units, code blocks, headings), diffs consecutive layouts to bound restyling, and defines the caret/delete rules (`EditRules`). The app target's `DocumentTextView` (an `NSTextView` in TextKit 1 mode) applies a layout as text attributes; a layout-manager delegate turns `.tvmvHidden` characters into null glyphs, so the text itself never changes. Every edit triggers a full re-parse — synchronous up to 64 KB, off the main thread above — and only the changed range is restyled.

**Tech Stack:** Swift 6 (language mode 6), SwiftPM, AppKit/TextKit 1, SwiftUI shell, swift-cmark (gfm branch, already a dependency), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-14-native-editor-design.md` (build steps 1–2). Later plans cover: lists/quotes/checkboxes/images (step 3), embedded blocks (step 4), the table grid (step 5), three-way merge (step 6), and review comments (`docs/superpowers/specs/2026-10-14-review-comments-design.md`).

**Provenance:** Every code block in this plan was compiled and its tests run (137 tests: 114 in TVMVCoreTests with 6 performance gates skipped, 23 in tvmvTests; 0 failures) in a throwaway clone of this repo on 2026-10-14, and the app was launched and screenshotted. Copy code exactly; where a step says "Expected: FAIL", the failure is the missing symbol, not a logic error.

## Global Constraints

- Platform floors stay as `Package.swift` declares: macOS 14, iOS 26. No new package dependencies.
- Swift 6 language mode (tools 6.0): code must compile under strict concurrency — the code below does.
- Tests run with the Xcode toolchain: prefix every `swift test` with `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- The shared web layer (`Sources/TVMVCore/Resources/web/`), iOS (`ios/`) and Linux (`linux/`) are untouched except where a task says so. `AppSettings` keeps every property (iOS uses the editor ones).
- Never hide text that is not markup: every hidden range goes through `LayoutBuilder.addMarker` validation.
- Commit after each task with a message in the repo's style (imperative sentence, no prefix tag).
- After each task, check that EVERY test bundle reports 0 failures (`swift test` prints one summary per bundle; the last line alone is not enough).

## Review Focus

Inputs the spec implies but per-feature tests could miss, most likely first. Each has a pinning test in the task named.

1. **Astral and CJK characters before markup** (emoji, 日本語): hidden ranges must stay aligned, or real text vanishes — `testAstralAndCJKCharactersKeepOffsetsAligned` (Task 2), `testColumnsCountBytesButOffsetsCountUTF16` (Task 1).
2. **Hard line breaks (`\` or two trailing spaces) before formatting:** cmark's own positions are wrong after them — `testHardLineBreaksDoNotShiftLaterPositions` (Task 2), plus the random-edit property test (Task 3).
3. **Typing an opening ```` ``` ```` mid-document** (everything below becomes code until it is closed) and other edits whose effect reaches far: restyling must cover the whole affected range — `testRandomEditsKeepInvariantsAndDiffsSound` (Task 3).
4. **Large documents while typing:** parsing must never block the main thread above 64 KB, and the result must still land — `testLargeDocumentsParseOffTheMainThreadAndApply` (Task 7).
5. **The file changing on disk while viewing:** the new text appears and the reading position holds; with unsaved edits it is NOT adopted — `testExternalChangeIsHandedToTheNativeView`, `testExternalChangeWithUnsavedEditsIsNotAdopted` (Task 6).

## File Structure

| File | Responsibility |
|---|---|
| `Sources/TVMVCore/SourceMap.swift` (new) | cmark (line, byte column) → UTF-16 offsets |
| `Sources/TVMVCore/MarkdownLayout.swift` (new) | The layout model: style runs, markers, reveal units, code blocks, headings, blocks, definitions |
| `Sources/TVMVCore/MarkdownLayoutParser.swift` (new) | cmark-gfm walk → `MarkdownLayout`, with position repair and marker validation |
| `Sources/TVMVCore/MarkdownLayoutDiff.swift` (new) | `changedRange(from:edit:delta:)` — bounds the restyle |
| `Sources/TVMVCore/HeadingSlugger.swift` (new) | Swift port of boot.js's GitHub slug algorithm |
| `Sources/TVMVCore/EditRules.swift` (new) | Caret snap, delete retarget, wrap/unwrap — pure |
| `Sources/TVMVCore/ReadingPositionStore.swift` (new) | Offset-based reading position/bookmark with legacy fallback |
| `Sources/TVMVCore/ViewerModel.swift` (modify) | `rendersPreview`, `onExternalTextAdopted`, native reading-position API |
| `Sources/TVMVCore/PreviewBridge.swift` (modify) | `printDocument(jobTitle:sheetWindow:)` |
| `Sources/tvmv/NativeTheme.swift` (new) | Fonts, palette, measure; attribute keys |
| `Sources/tvmv/DocumentStyler.swift` (new) | Applies a layout to an `NSTextStorage` range |
| `Sources/tvmv/DocumentTextView.swift` (new) | The native reader/editor view |
| `Sources/tvmv/NativeDocumentView.swift` (new) | SwiftUI wrapper + `NativeDocumentController` |
| `Sources/tvmv/PrintRenderer.swift` (new) | Print/Save-as-PDF via an offscreen web view |
| `Sources/tvmv/ViewerWindow.swift`, `ViewerCommands.swift`, `SettingsView.swift` (modify) | Host the native view; menus; settings cleanup |
| `Sources/tvmv/CodeMirrorEditorPane.swift`, `MarkdownWebView.swift` (delete) | Retired on macOS (iOS/Linux have their own) |
| `README.md` (modify) | Describe macOS editing and the custom-CSS scope |

---

### Task 1: SourceMap

**Files:**
- Create: `Sources/TVMVCore/SourceMap.swift`
- Test: `Tests/TVMVCoreTests/SourceMapTests.swift`

**Interfaces:**
- Produces: `public struct SourceMap` with `init(_ text: String)`, `offset(line:column:) -> Int?`, `endOffset(line:column:) -> Int?`, `range(startLine:startColumn:endLine:endColumn:) -> NSRange?`. cmark columns are 1-based UTF-8 byte columns; results are UTF-16 offsets. Column 0 in an end position means "end of the previous line".

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TVMVCore

final class SourceMapTests: XCTestCase {
    func testASCIIPositions() {
        let map = SourceMap("ab\ncd\n")
        XCTAssertEqual(map.offset(line: 1, column: 1), 0)
        XCTAssertEqual(map.offset(line: 2, column: 2), 4)
        XCTAssertEqual(map.range(startLine: 2, startColumn: 1, endLine: 2, endColumn: 2),
                       NSRange(location: 3, length: 2))
    }

    func testColumnsCountBytesButOffsetsCountUTF16() {
        // "é" is 2 UTF-8 bytes and 1 UTF-16 unit; "😀" is 4 bytes and 2 units.
        let map = SourceMap("é😀x\n")
        XCTAssertEqual(map.offset(line: 1, column: 1), 0)   // é
        XCTAssertEqual(map.offset(line: 1, column: 3), 1)   // 😀 starts at byte 3
        XCTAssertEqual(map.offset(line: 1, column: 7), 3)   // x
        XCTAssertEqual(map.range(startLine: 1, startColumn: 3, endLine: 1, endColumn: 6),
                       NSRange(location: 1, length: 2))
        // A position naming a continuation byte snaps to its character.
        XCTAssertEqual(map.offset(line: 1, column: 4), 1)
        XCTAssertEqual(map.endOffset(line: 1, column: 4), 3)
    }

    func testColumnZeroMeansEndOfPreviousLine() {
        XCTAssertEqual(SourceMap("ab\ncd\n").endOffset(line: 2, column: 0), 3)
    }

    func testMissingPositionsAreNil() {
        let map = SourceMap("ab\n")
        XCTAssertNil(map.offset(line: 0, column: 0))
        XCTAssertNil(map.offset(line: 9, column: 1))
        XCTAssertNil(map.range(startLine: 0, startColumn: 0, endLine: 0, endColumn: 0))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SourceMapTests`
Expected: FAIL — `cannot find 'SourceMap' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Converts cmark's 1-based (line, byte column) source positions into UTF-16
/// offsets — the unit NSString, NSTextView and TextPatcher use.
///
/// cmark counts columns in UTF-8 bytes. A position can name any byte of a
/// multi-byte character, so offsets snap to the character containing it, and
/// exclusive ends snap forward to the next character boundary.
public struct SourceMap {
    private let bytes: [UInt8]
    /// Byte offset where each line starts (index 0 is line 1).
    private let lineStarts: [Int]
    /// UTF-16 offset of the character containing each byte; one extra entry
    /// for the end of the text.
    private let utf16AtByte: [Int32]

    public init(_ text: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var utf16AtByte: [Int32] = []
        utf16AtByte.reserveCapacity(text.utf8.count + 1)
        var lineStarts = [0]
        var u16: Int32 = 0
        for scalar in text.unicodeScalars {
            let encoded = UTF8.encode(scalar)!
            for byte in encoded {
                bytes.append(byte)
                utf16AtByte.append(u16)
            }
            u16 += Int32(UTF16.width(scalar))
            if scalar == "\n" { lineStarts.append(bytes.count) }
        }
        utf16AtByte.append(u16)
        self.bytes = bytes
        self.lineStarts = lineStarts
        self.utf16AtByte = utf16AtByte
    }

    /// UTF-16 offset of the character at (line, column); nil when cmark
    /// reported no position (line 0) or the position is out of range.
    public func offset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= lineStarts.count, column >= 1 else { return nil }
        let byte = lineStarts[line - 1] + column - 1
        guard byte < utf16AtByte.count else { return nil }
        return Int(utf16AtByte[byte])
    }

    /// UTF-16 offset just past the character at (line, column). Column 0
    /// means "the end of the previous line", which cmark uses for container
    /// blocks that end at a blank line.
    public func endOffset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= lineStarts.count, column >= 0 else { return nil }
        var byte = lineStarts[line - 1] + column
        guard byte <= bytes.count else { return nil }
        while byte < bytes.count, bytes[byte] & 0xC0 == 0x80 { byte += 1 }   // skip continuation bytes
        return Int(utf16AtByte[byte])
    }

    /// The UTF-16 range for cmark's inclusive start/end positions.
    public func range(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) -> NSRange? {
        guard let start = offset(line: startLine, column: startColumn),
              let end = endOffset(line: endLine, column: endColumn), end >= start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SourceMapTests`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/TVMVCore/SourceMap.swift Tests/TVMVCoreTests/SourceMapTests.swift
git commit -m "Map cmark source positions to UTF-16 offsets"
```

---

### Task 2: MarkdownLayout and its parser

The parser walks cmark-gfm's AST (same options/extensions as `renderHTML`) and records, per construct, a style run, the **markers** (markup characters to hide) and the **reveal unit** (the span a double-click reveals). Facts about the pinned cmark that this code relies on — all measured on 2026-10-14:

- Emphasis/strong/strikethrough/link/image/`<autolink>` ranges include their delimiters; code-span ranges cover the content only (the code widens them over the backtick runs).
- Extension autolinks (`www.…`) start one character early; the code re-finds the link text.
- After a hard line break, inline positions in the rest of the paragraph are wrong, and a block containing one can report a wrong end. The code re-parses such paragraphs segment by segment, and clamps every block to its next sibling's start.
- Nested delimiter runs (`***x***`) give the inner node the outer node's range; after astral characters an end can be one short. Both get bounded repairs; anything still doubtful is **styled but not hidden** — `addMarker` refuses overlaps and the delimiter characters are validated.
- An ATX heading's range stops before a closing ` ##`; setext and fenced-code lines are validated before they collapse.

**Files:**
- Create: `Sources/TVMVCore/MarkdownLayout.swift`
- Create: `Sources/TVMVCore/MarkdownLayoutParser.swift`
- Test: `Tests/TVMVCoreTests/MarkdownLayoutParserTests.swift`

**Interfaces:**
- Consumes: `SourceMap` (Task 1).
- Produces: `public struct MarkdownLayout: Equatable, Sendable` with `length`, `styles: [StyleRun]`, `markers: [Marker]` (`range`, `unit`, `collapsesLine`), `spellExempt: [NSRange]`, `codeBlocks: [CodeBlock]` (`range`, `body`), `headings: [Heading]` (`level`, `title`, `range`), `blocks: [Block]`, `definitions: [Definition]`, computed `revealUnits: [NSRange]`; `MarkdownLayout.Style` cases `emphasis, strong, strikethrough, code, link(url:), autolink(url:), heading(level:), codeBlock(language:), html, image`; `public enum MarkdownLayoutParser { static func parse(_ text: String) -> MarkdownLayout }`; `extension NSRange { public func encloses(_:) -> Bool; public func shifted(by:) -> NSRange }`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import TVMVCore

final class MarkdownLayoutParserTests: XCTestCase {
    /// The text each marker hides, in source order.
    private func hidden(_ text: String) -> [String] {
        let ns = text as NSString
        return MarkdownLayoutParser.parse(text).markers
            .sorted { $0.range.location < $1.range.location }
            .map { ns.substring(with: $0.range) }
    }

    /// The text of every style run matching `match`, in source order.
    private func styled(_ text: String, _ match: (MarkdownLayout.Style) -> Bool) -> [String] {
        let ns = text as NSString
        return MarkdownLayoutParser.parse(text).styles
            .filter { match($0.style) }
            .sorted { $0.range.location < $1.range.location }
            .map { ns.substring(with: $0.range) }
    }

    func testEmphasisStrongAndStrikethroughHideOnlyTheirDelimiters() {
        let text = "a **b** _c_ ~~d~~ ***e***\n"
        XCTAssertEqual(hidden(text), ["**", "**", "_", "_", "~~", "~~", "*", "**", "**", "*"])
        XCTAssertEqual(styled(text) { $0 == .strong }, ["b", "e"])
        XCTAssertEqual(styled(text) { $0 == .emphasis }, ["c", "**e**"])
        XCTAssertEqual(styled(text) { $0 == .strikethrough }, ["d"])
    }

    func testATXHeadingHidesPrefixAndClosingHashes() {
        let text = "## Title *x* ##\n"
        XCTAssertEqual(hidden(text), ["## ", "*", "*", " ##"])
        let layout = MarkdownLayoutParser.parse(text)
        XCTAssertEqual(layout.headings.map(\.level), [2])
        XCTAssertEqual(layout.headings.map(\.title), ["Title x"])
    }

    func testSetextUnderlineCollapses() {
        let text = "Title\n=====\n\nbody\n"
        let layout = MarkdownLayoutParser.parse(text)
        XCTAssertEqual(hidden(text), ["=====\n"])
        XCTAssertEqual(layout.markers.map(\.collapsesLine), [true])
        XCTAssertEqual(layout.headings.map(\.title), ["Title"])
    }

    func testFencedCodeCollapsesFencesAndKeepsTheBody() {
        let text = "```swift\nlet x = 1\n```\nafter\n"
        let ns = text as NSString
        let layout = MarkdownLayoutParser.parse(text)
        XCTAssertEqual(hidden(text), ["```swift\n", "```\n"])
        XCTAssertEqual(layout.markers.map(\.collapsesLine), [true, true])
        XCTAssertEqual(layout.codeBlocks.map { ns.substring(with: $0.body) }, ["let x = 1"])
        XCTAssertTrue(layout.styles.contains { $0.style == .codeBlock(language: "swift") })
    }

    func testUnclosedFenceHidesOnlyTheOpeningLine() {
        XCTAssertEqual(hidden("```\nstill open\n"), ["```\n"])
    }

    func testCodeSpansHideTheirBacktickRuns() {
        XCTAssertEqual(hidden("a `c` b\n"), ["`", "`"])
        XCTAssertEqual(hidden("a `` x`y `` b\n"), ["``", "``"])
    }

    func testLinksAndAutolinks() {
        let text = "[text](http://a.b \"t\") [ref][r] <http://c.d> www.e.com\n\n[r]: http://r.s\n"
        XCTAssertEqual(hidden(text), ["[", "](http://a.b \"t\")", "[", "][r]", "<", ">"])
        let layout = MarkdownLayoutParser.parse(text)
        let ns = text as NSString
        let links = layout.styles.compactMap { run -> String? in
            switch run.style {
            case .link(let url), .autolink(let url): return "\(ns.substring(with: run.range)) -> \(url)"
            default: return nil
            }
        }
        XCTAssertEqual(links, ["text -> http://a.b", "ref -> http://r.s",
                               "http://c.d -> http://c.d", "www.e.com -> http://www.e.com"])
        XCTAssertEqual(layout.definitions.map(\.text), ["[r]: http://r.s"])
    }

    func testHardLineBreaksDoNotShiftLaterPositions() {
        // cmark's own inline positions are wrong after a hard break.
        let text = "a\\\nb *c* d  \ne **f**\n"
        XCTAssertEqual(hidden(text), ["*", "*", "**", "**"])
        XCTAssertEqual(styled(text) { $0 == .emphasis }, ["c"])
        XCTAssertEqual(styled(text) { $0 == .strong }, ["f"])
    }

    func testAstralAndCJKCharactersKeepOffsetsAligned() {
        let text = "é😀*x* 日本 **語**\n"
        XCTAssertEqual(hidden(text), ["*", "*", "**", "**"])
        XCTAssertEqual(styled(text) { $0 == .emphasis }, ["x"])
        XCTAssertEqual(styled(text) { $0 == .strong }, ["語"])
    }

    func testInlinePositionsInsideQuotesListsAndTables() {
        let text = "> quote *q*\n\n- item **one**\n- [ ] task `c`\n\n| A | *B* |\n|---|---|\n| 1 | `2` |\n"
        XCTAssertEqual(hidden(text), ["*", "*", "**", "**", "`", "`", "*", "*", "`", "`"])
    }

    func testSpellExemptions() {
        let text = "see `wrongg` and [l](http://wrongg.x)\n"
        let ns = text as NSString
        XCTAssertEqual(MarkdownLayoutParser.parse(text).spellExempt.map { ns.substring(with: $0) },
                       ["`wrongg`", "](http://wrongg.x)"])
    }

    func testEmptyAndMarkupFreeDocuments() {
        XCTAssertEqual(MarkdownLayoutParser.parse("").markers, [])
        XCTAssertEqual(MarkdownLayoutParser.parse("plain words").markers, [])
        XCTAssertEqual(MarkdownLayoutParser.parse("plain words").length, 11)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MarkdownLayoutParserTests`
Expected: FAIL — `cannot find 'MarkdownLayoutParser' in scope`.

- [ ] **Step 3: Write the model**

`Sources/TVMVCore/MarkdownLayout.swift`:

```swift
import Foundation

/// Everything the native view needs to draw a Markdown text in place: which
/// ranges get which style, which markup characters hide, and which spans
/// reveal together. All ranges are UTF-16 ranges in the source text.
public struct MarkdownLayout: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case emphasis, strong, strikethrough, code
        case link(url: String)
        case autolink(url: String)
        case heading(level: Int)
        case codeBlock(language: String?)
        case html
        case image
    }

    public struct StyleRun: Equatable, Sendable {
        public var range: NSRange
        public var style: Style
        public init(range: NSRange, style: Style) { self.range = range; self.style = style }
    }

    /// Markup that is hidden unless the span it belongs to is revealed.
    public struct Marker: Equatable, Sendable {
        public var range: NSRange
        /// The construct this marker belongs to — the span a double-click or
        /// ⌘' reveals. Revealing a unit shows all of its markers.
        public var unit: NSRange
        /// The marker is a whole line (a code fence, a setext underline),
        /// including its newline, and collapses to zero height when hidden.
        public var collapsesLine: Bool
        public init(range: NSRange, unit: NSRange, collapsesLine: Bool = false) {
            self.range = range; self.unit = unit; self.collapsesLine = collapsesLine
        }
    }

    public struct CodeBlock: Equatable, Sendable {
        /// The whole block, fences included.
        public var range: NSRange
        /// The code lines only (what gets the block background).
        public var body: NSRange
    }

    public struct Heading: Equatable, Sendable {
        public var level: Int
        /// Rendered text: markup removed, soft breaks as spaces, trimmed.
        public var title: String
        public var range: NSRange
    }

    /// A top-level block: the resync points of the incremental re-parse.
    public struct Block: Equatable, Sendable {
        public var range: NSRange
        public var kind: String
    }

    public var length = 0
    public var styles: [StyleRun] = []
    public var markers: [Marker] = []
    public var spellExempt: [NSRange] = []
    public var codeBlocks: [CodeBlock] = []
    public var headings: [Heading] = []
    public var blocks: [Block] = []
    /// Link reference definition lines (`[label]: url`) outside code. Partial
    /// re-parses are wrapped with them so reference links resolve exactly as
    /// in a full parse.
    public var definitions: [Definition] = []

    public struct Definition: Equatable, Sendable {
        public var range: NSRange
        public var text: String
    }

    public init() {}

    /// Every reveal unit, in source order without duplicates.
    public var revealUnits: [NSRange] {
        var seen = Set<NSRange>()
        return markers.compactMap { seen.insert($0.unit).inserted ? $0.unit : nil }
    }
}

extension NSRange {
    /// True when `inner` lies entirely within self (an empty `inner` may sit at either end).
    public func encloses(_ inner: NSRange) -> Bool {
        inner.location >= location && NSMaxRange(inner) <= NSMaxRange(self)
    }
    public func shifted(by delta: Int) -> NSRange { NSRange(location: location + delta, length: length) }
}
```

- [ ] **Step 4: Write the parser**

`Sources/TVMVCore/MarkdownLayoutParser.swift`:

```swift
import Foundation
import cmark_gfm
import cmark_gfm_extensions

typealias CMarkNode = UnsafeMutablePointer<cmark_node>

/// Parses Markdown with the same pinned cmark-gfm (and the same four GFM
/// extensions) as `renderHTML`, so the editor and the printed output can
/// never disagree about what the text means.
enum CMark {
    static func withDocument<T>(_ text: String, _ body: (CMarkNode) -> T) -> T? {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_SOURCEPOS) else { return nil }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }
        // Real UTF-8 byte count, not strlen — see renderHTML.
        let utf8 = Array(text.utf8)
        utf8.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                cmark_parser_feed(parser, $0, buffer.count)
            }
        }
        guard let document = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(document) }
        return body(document)
    }

    static func type(_ node: CMarkNode) -> String { String(cString: cmark_node_get_type_string(node)) }

    static func children(_ node: CMarkNode) -> [CMarkNode] {
        var out: [CMarkNode] = []
        var child = cmark_node_first_child(node)
        while let c = child { out.append(c); child = cmark_node_next(c) }
        return out
    }

    static func literal(_ node: CMarkNode) -> String {
        cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
    }
}

public enum MarkdownLayoutParser {
    /// Full parse of `text`.
    public static func parse(_ text: String) -> MarkdownLayout {
        let ns = text as NSString
        let all = definitions(in: ns, range: NSRange(location: 0, length: ns.length))
        var builder = LayoutBuilder(text: text, at: 0, wrapWith: [], definitions: all, recordBlocks: true)
        builder.parse()
        var layout = builder.layout
        layout.length = ns.length
        let code = layout.codeBlocks.map(\.range)
        layout.definitions = all.filter { d in !code.contains { NSIntersectionRange($0, d.range).length > 0 } }
        return layout
    }

    /// Link reference definition lines: `[label]: destination ...`, up to
    /// three spaces of indent. Footnote-style labels (`[^x]:`) are included —
    /// with footnotes off, cmark treats them as reference definitions too.
    static let definitionPattern = try! NSRegularExpression(
        pattern: #"^ {0,3}\[[^\]\n]+\]:[^\n]*$"#, options: .anchorsMatchLines)

    static func definitions(in text: NSString, range: NSRange) -> [MarkdownLayout.Definition] {
        definitionPattern.matches(in: text as String, range: range)
            .map { .init(range: $0.range, text: text.substring(with: $0.range)) }
    }
}

/// Walks one cmark document and accumulates a `MarkdownLayout`.
///
/// The parsed source is the text of interest, optionally wrapped: definition
/// lines from elsewhere in the document before and after it (they produce no
/// blocks, so they only make reference links resolve), and a sentinel just
/// before it. Offsets convert back to document offsets via `adjust`.
struct LayoutBuilder {
    let ns: NSString
    let map: SourceMap
    /// Document offset = source offset + adjust.
    let adjust: Int
    /// Where the text of interest (including any sentinel) starts and ends in the source.
    let contentStart: Int
    let contentEnd: Int
    let recordBlocks: Bool
    /// Every definition in the document, for segment re-parses.
    let definitions: [MarkdownLayout.Definition]
    var layout = MarkdownLayout()
    /// Source offsets already hidden by some marker: a character belongs to
    /// at most one marker, whatever cmark's positions claim.
    var claimed = IndexSet()

    init(text: String, at docLocation: Int, sentinel: String = "",
         wrapWith wrap: [MarkdownLayout.Definition], definitions: [MarkdownLayout.Definition],
         recordBlocks: Bool) {
        let before = wrap.filter { $0.range.location < docLocation }.map(\.text)
        let after = wrap.filter { $0.range.location >= docLocation }.map(\.text)
        let prefix = before.isEmpty ? "" : before.joined(separator: "\n") + "\n\n"
        let suffix = after.isEmpty ? "" : "\n\n" + after.joined(separator: "\n")
        let source = prefix + sentinel + text + suffix
        ns = source as NSString
        map = SourceMap(source)
        contentStart = (prefix as NSString).length
        let sentinelLength = (sentinel as NSString).length
        contentEnd = contentStart + sentinelLength + (text as NSString).length
        adjust = docLocation - contentStart - sentinelLength
        self.recordBlocks = recordBlocks
        self.definitions = definitions
    }

    mutating func parse() {
        _ = CMark.withDocument(ns as String) { doc in
            let blocks = CMark.children(doc)
            for (i, block) in blocks.enumerated() {
                guard var r = localRange(block), r.location >= contentStart, r.location < contentEnd else { continue }
                let limit = i + 1 < blocks.count ? (localRange(blocks[i + 1])?.location ?? ns.length) : ns.length
                r.length = min(r.length, max(0, limit - r.location))
                if recordBlocks {
                    layout.blocks.append(.init(range: docRange(r), kind: CMark.type(block)))
                }
                visitBlock(block, limit: limit)
            }
        }
        layout.styles.removeAll { $0.range.length == 0 }
        layout.spellExempt.removeAll { $0.length == 0 }
    }

    // MARK: Ranges

    /// Range of `node` in the parsed text (no adjustment); nil without a position.
    func localRange(_ node: CMarkNode) -> NSRange? {
        map.range(startLine: Int(cmark_node_get_start_line(node)),
                  startColumn: Int(cmark_node_get_start_column(node)),
                  endLine: Int(cmark_node_get_end_line(node)),
                  endColumn: Int(cmark_node_get_end_column(node)))
    }

    func docRange(_ local: NSRange) -> NSRange { local.shifted(by: adjust) }

    /// The line containing `location`, with its newline.
    func lineRange(at location: Int) -> NSRange {
        ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
    }

    /// Record a marker unless it overlaps one already recorded. Every hide
    /// goes through here: hiding real text is the worst failure this layer
    /// can have, so anything doubtful stays visible instead.
    mutating func addMarker(_ local: NSRange, unit: NSRange, collapsesLine: Bool = false) {
        guard local.length > 0, NSMaxRange(local) <= ns.length,
              !claimed.intersects(integersIn: local.location..<NSMaxRange(local)) else { return }
        claimed.insert(integersIn: local.location..<NSMaxRange(local))
        layout.markers.append(.init(range: docRange(local), unit: unit, collapsesLine: collapsesLine))
    }

    func isRun(_ r: NSRange, of characters: Set<unichar>) -> Bool {
        guard r.location >= 0, NSMaxRange(r) <= ns.length, r.length > 0 else { return false }
        return (r.location..<NSMaxRange(r)).allSatisfy { characters.contains(ns.character(at: $0)) }
    }

    // MARK: Blocks

    /// `limit` is where the next sibling block starts. cmark's end position
    /// is wrong for blocks containing a hard line break, so every block range
    /// is clamped to it.
    mutating func visitBlock(_ node: CMarkNode, limit: Int) {
        guard var r = localRange(node) else { return }
        r.length = min(r.length, max(0, limit - r.location))
        switch CMark.type(node) {
        case "heading":
            visitHeading(node, r)
        case "paragraph", "table_cell":
            visitInlineContainer(node, r)
        case "code_block":
            visitCodeBlock(node, r)
        case "html_block":
            layout.styles.append(.init(range: docRange(r), style: .html))
            layout.spellExempt.append(docRange(r))
        default:
            let children = CMark.children(node)
            for (i, child) in children.enumerated() {
                let next = i + 1 < children.count ? (localRange(children[i + 1])?.location ?? limit) : limit
                visitBlock(child, limit: min(next, limit))
            }
        }
    }

    mutating func visitHeading(_ node: CMarkNode, _ r: NSRange) {
        let level = Int(cmark_node_get_heading_level(node))
        let firstLine = lineRange(at: r.location)
        var lineEnd = NSMaxRange(firstLine)
        if lineEnd > firstLine.location, ns.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
        // The unit spans the whole heading: cmark's ATX range stops before a closing " ##".
        let unit = docRange(NSUnionRange(NSUnionRange(r, NSRange(location: r.location, length: lineEnd - r.location)),
                                         lineRange(at: max(r.location, NSMaxRange(r) - 1))))
        layout.styles.append(.init(range: unit, style: .heading(level: level)))
        if NSMaxRange(firstLine) < NSMaxRange(r) {
            // Setext: the underline is the last line; it collapses away.
            let underline = lineRange(at: NSMaxRange(r) - 1)
            let text = ns.substring(with: underline).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text.allSatisfy({ $0 == "=" }) || text.allSatisfy({ $0 == "-" }) {
                addMarker(underline, unit: unit, collapsesLine: true)
            }
        } else {
            // ATX: hide "# " up to the content, and an optional closing " ##".
            let content = CMark.children(node).first.flatMap { localRange($0) }
            let contentStart = content?.location ?? NSMaxRange(r)
            if contentStart > r.location {
                let prefix = NSRange(location: r.location, length: contentStart - r.location)
                if isRun(prefix, of: [35, 32, 9]) { addMarker(prefix, unit: unit) }   // "#", space, tab
            }
            // cmark's heading range stops before a closing " ##"; look on the whole line.
            var line = firstLine
            if line.length > 0, ns.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
            if let closing = Self.closingHashes.firstMatch(in: ns as String, range: line),
               closing.range.location >= contentStart {
                addMarker(closing.range, unit: unit)
            }
        }
        let title = Self.plainText(node).trimmingCharacters(in: .whitespaces)
        layout.headings.append(.init(level: level, title: title, range: unit))
        visitInlineContainer(node, r)
    }

    static let closingHashes = try! NSRegularExpression(pattern: #"[ \t]+#+[ \t]*$"#)

    static func plainText(_ node: CMarkNode) -> String {
        switch CMark.type(node) {
        case "text", "code": return CMark.literal(node)
        case "softbreak", "linebreak": return " "
        default: return CMark.children(node).map(plainText).joined()
        }
    }

    mutating func visitCodeBlock(_ node: CMarkNode, _ r: NSRange) {
        // The unit spans the fence lines whole (container prefixes and newline included).
        let unit = docRange(NSUnionRange(NSUnionRange(r, lineRange(at: r.location)),
                                         lineRange(at: max(r.location, NSMaxRange(r) - 1))))
        var length: Int32 = 0, offset: Int32 = 0
        var character: CChar = 0
        let fenced = cmark_node_get_fenced(node, &length, &offset, &character) != 0
        let fence = String(repeating: String(UnicodeScalar(UInt8(bitPattern: character))), count: Int(length))
        let open = lineRange(at: r.location)
        var body = r
        if fenced, length > 0, ns.substring(with: open).contains(fence) {
            addMarker(open, unit: unit, collapsesLine: true)
            body = NSRange(location: NSMaxRange(open), length: max(0, NSMaxRange(r) - NSMaxRange(open)))
            let close = lineRange(at: NSMaxRange(r) - 1)
            if close.location > open.location,
               ns.substring(with: close).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(fence) {
                addMarker(close, unit: unit, collapsesLine: true)
                body.length = max(0, close.location - body.location)
            }
            // The body's final newline belongs to the closing fence's line break.
            if body.length > 0, ns.character(at: NSMaxRange(body) - 1) == 10 { body.length -= 1 }
        }
        let info = cmark_node_get_fence_info(node).map { String(cString: $0) } ?? ""
        let language = info.split(separator: " ").first.map(String.init)
        layout.styles.append(.init(range: unit, style: .codeBlock(language: language)))
        layout.spellExempt.append(unit)
        layout.codeBlocks.append(.init(range: unit, body: docRange(body)))
    }

    // MARK: Inlines

    /// Inline content of a paragraph, heading, or table cell. cmark's inline
    /// positions are wrong after a hard line break (the line number sticks
    /// and columns run on), so such containers are re-parsed segment by
    /// segment, each segment on its own.
    mutating func visitInlineContainer(_ node: CMarkNode, _ r: NSRange) {
        guard Self.containsHardBreak(node) else {
            for child in CMark.children(node) { _ = visitInline(child) }
            return
        }
        var segmentStart = r.location
        var lineStart = r.location
        while lineStart < NSMaxRange(r) {
            let line = lineRange(at: lineStart)
            let lineEnd = min(NSMaxRange(line), NSMaxRange(r))
            let text = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            let content = text.hasSuffix("\n") ? String(text.dropLast()) : text
            if content.hasSuffix("\\") || content.hasSuffix("  ") || lineEnd == NSMaxRange(r) {
                visitSegment(NSRange(location: segmentStart, length: lineEnd - segmentStart))
                segmentStart = lineEnd
            }
            lineStart = lineEnd
        }
    }

    static func containsHardBreak(_ node: CMarkNode) -> Bool {
        CMark.children(node).contains { CMark.type($0) == "linebreak" || containsHardBreak($0) }
    }

    /// Parse one hard-break segment as its own document. The "." sentinel
    /// keeps its first line from parsing as a block start ("# ", "- ", ">").
    /// An emphasis that spans a hard break degrades to literal text here.
    mutating func visitSegment(_ segment: NSRange) {
        let docLocation = segment.location + adjust
        var sub = LayoutBuilder(text: ns.substring(with: segment), at: docLocation, sentinel: ".",
                                wrapWith: definitions, definitions: definitions, recordBlocks: false)
        _ = CMark.withDocument(sub.ns as String) { doc in
            for block in CMark.children(doc) where CMark.type(block) == "paragraph" {
                guard let r = sub.localRange(block), r.location >= sub.contentStart, r.location < sub.contentEnd
                else { continue }
                for child in CMark.children(block) { sub.visitInline(child) }
            }
        }
        layout.styles += sub.layout.styles.filter { $0.range.length > 0 }
        layout.markers += sub.layout.markers
        layout.spellExempt += sub.layout.spellExempt
    }

    /// Visit one inline node; returns its end offset in the parsed text (or nil).
    @discardableResult
    mutating func visitInline(_ node: CMarkNode) -> Int? {
        let kind = CMark.type(node)
        guard let r = localRange(node) else {
            for child in CMark.children(node) { visitInline(child) }
            return nil
        }
        switch kind {
        case "emph", "strong", "strikethrough":
            let delimiters: Set<unichar> = kind == "strikethrough" ? [126] : [42, 95]   // "~" / "*", "_"
            let count = kind == "emph" ? 1 : kind == "strong" ? 2 : tildeRun(at: r.location)
            let style: MarkdownLayout.Style = kind == "emph" ? .emphasis : kind == "strong" ? .strong : .strikethrough
            var span = r
            // Nested runs ("***x***"): cmark gives the inner node the outer
            // node's range. Step inside delimiters an enclosing node claimed.
            var inset = 0
            while inset < 3, span.length > 2, claimed.contains(span.location), claimed.contains(NSMaxRange(span) - 1) {
                span = NSRange(location: span.location + 1, length: span.length - 2); inset += 1
            }
            // cmark occasionally reports the end a character short (after
            // astral characters); allow a small bounded repair, nothing more.
            var repair = 0
            while repair < 3,
                  !isRun(NSRange(location: NSMaxRange(span) - count, length: count), of: delimiters),
                  NSMaxRange(span) < ns.length {
                span.length += 1; repair += 1
            }
            let open = NSRange(location: span.location, length: count)
            let close = NSRange(location: NSMaxRange(span) - count, length: count)
            if span.length >= 2 * count, isRun(open, of: delimiters), isRun(close, of: delimiters),
               !claimed.intersects(integersIn: open.location..<NSMaxRange(open)),
               !claimed.intersects(integersIn: close.location..<NSMaxRange(close)) {
                let unit = docRange(span)
                layout.styles.append(.init(
                    range: docRange(NSRange(location: span.location + count, length: span.length - 2 * count)), style: style))
                addMarker(open, unit: unit)
                addMarker(close, unit: unit)
            } else {
                layout.styles.append(.init(range: docRange(r), style: style))   // styled, nothing hidden
            }
            for child in CMark.children(node) { visitInline(child) }
        case "code":
            visitCodeSpan(r)
        case "link":
            visitLink(node, r)
        case "image":
            layout.styles.append(.init(range: docRange(r), style: .image))
            layout.spellExempt.append(docRange(r))
        case "html_inline":
            layout.styles.append(.init(range: docRange(r), style: .html))
            layout.spellExempt.append(docRange(r))
        default:
            for child in CMark.children(node) { visitInline(child) }
        }
        return NSMaxRange(r)
    }

    func tildeRun(at location: Int) -> Int {
        var n = 0
        while location + n < ns.length, ns.character(at: location + n) == 126 { n += 1 }   // "~"
        return max(1, n)
    }

    /// cmark's code-span range covers the content only; widen it over the
    /// backtick runs (and the one space of padding cmark strips each side).
    mutating func visitCodeSpan(_ content: NSRange) {
        let backtick: unichar = 96, space: unichar = 32
        func ticks(endingAt i: Int) -> Int {
            var n = 0
            while i - n - 1 >= 0, ns.character(at: i - n - 1) == backtick { n += 1 }
            return n
        }
        func ticks(startingAt i: Int) -> Int {
            var n = 0
            while i + n < ns.length, ns.character(at: i + n) == backtick { n += 1 }
            return n
        }
        // Opening run, with or without one stripped padding space.
        var left = content.location
        var count = ticks(endingAt: left)
        if count == 0, left > 0, ns.character(at: left - 1) == space {
            left -= 1
            count = ticks(endingAt: left)
        }
        var right = NSMaxRange(content)
        if ticks(startingAt: right) != count, right < ns.length, ns.character(at: right) == space {
            right += 1
        }
        guard count > 0, ticks(startingAt: right) == count else {
            layout.styles.append(.init(range: docRange(content), style: .code))
            layout.spellExempt.append(docRange(content))
            return
        }
        let open = left - count, close = right + count
        let unit = docRange(NSRange(location: open, length: close - open))
        layout.styles.append(.init(range: docRange(content), style: .code))
        layout.spellExempt.append(unit)
        addMarker(NSRange(location: open, length: content.location - open), unit: unit)
        addMarker(NSRange(location: NSMaxRange(content), length: close - NSMaxRange(content)), unit: unit)
    }

    mutating func visitLink(_ node: CMarkNode, _ raw: NSRange) {
        let url = cmark_node_get_url(node).map { String(cString: $0) } ?? ""
        var r = raw
        let first = r.length > 0 ? ns.character(at: r.location) : 0
        let last = r.length > 0 ? ns.character(at: NSMaxRange(r) - 1) : 0
        switch first {
        case 60 where last == 62:   // "<…>" — angle autolink
            guard r.length >= 2 else { return }
            let unit = docRange(r)
            let inner = NSRange(location: r.location + 1, length: r.length - 2)
            layout.styles.append(.init(range: docRange(inner), style: .autolink(url: url)))
            layout.spellExempt.append(unit)
            addMarker(NSRange(location: r.location, length: 1), unit: unit)
            addMarker(NSRange(location: NSMaxRange(r) - 1, length: 1), unit: unit)
        case 91:   // "[" — inline or reference link
            var labelEnd = r.location + 1
            for child in CMark.children(node) {
                if let end = visitInline(child) { labelEnd = max(labelEnd, end) }
            }
            var close = labelEnd
            while close < NSMaxRange(r), ns.character(at: close) != 93 { close += 1 }   // "]"
            guard close < NSMaxRange(r) else { return }
            let tailText = ns.substring(with: NSRange(location: close, length: NSMaxRange(r) - close))
            guard tailText == "]" || (tailText.hasPrefix("](") && tailText.hasSuffix(")"))
                    || (tailText.hasPrefix("][") && tailText.hasSuffix("]")) else { return }
            let unit = docRange(r)
            layout.styles.append(.init(
                range: docRange(NSRange(location: r.location + 1, length: close - r.location - 1)), style: .link(url: url)))
            addMarker(NSRange(location: r.location, length: 1), unit: unit)
            let tail = NSRange(location: close, length: NSMaxRange(r) - close)
            addMarker(tail, unit: unit)
            if tail.length > 1 { layout.spellExempt.append(docRange(tail)) }
        default:
            // Extension autolink (www.…, bare URL, email): cmark's range
            // starts one character early. Locate the link text itself.
            let shown = Self.plainText(node)
            let search = NSIntersectionRange(NSRange(location: r.location, length: r.length + 1),
                                             NSRange(location: 0, length: ns.length))
            let found = ns.range(of: shown, options: [], range: search)
            guard found.location != NSNotFound, !shown.isEmpty else { return }
            r = found
            layout.styles.append(.init(range: docRange(r), style: .autolink(url: url)))
            layout.spellExempt.append(docRange(r))
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MarkdownLayoutParserTests`
Expected: 12 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/TVMVCore/MarkdownLayout.swift Sources/TVMVCore/MarkdownLayoutParser.swift Tests/TVMVCoreTests/MarkdownLayoutParserTests.swift
git commit -m "Parse Markdown into a layout of styles and hideable markup"
```

---

### Task 3: Layout diff, and the random-edit property test

Every edit re-parses the whole text (a block-level incremental re-parse was prototyped and diverged from full parses in 13–79 of 1,500 random edits). To keep restyling local, `changedRange` compares the old and new layouts: entries before the edit must match as-is, entries after it must match shifted by `delta`; the span between the first and last mismatch is restyled. The property test drives 1,800 random edits over the showcase fixture and checks (a) nothing but markup is ever hidden, and (b) nothing changed outside the reported range.

**Files:**
- Create: `Sources/TVMVCore/MarkdownLayoutDiff.swift`
- Test: `Tests/TVMVCoreTests/MarkdownLayoutPropertyTests.swift`

**Interfaces:**
- Consumes: `MarkdownLayout`, `MarkdownLayoutParser` (Task 2).
- Produces: `extension MarkdownLayout { public func changedRange(from old: MarkdownLayout, edit: NSRange, delta: Int) -> NSRange }` — `edit` is the replaced range in the OLD text, `delta` the length change; the result is a range in the NEW text.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MarkdownLayoutPropertyTests`
Expected: FAIL — `value of type 'MarkdownLayout' has no member 'changedRange'`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

extension MarkdownLayout {
    /// The smallest range of the NEW text whose styling differs between
    /// `old` (the layout before an edit) and `self` (a full parse after it).
    ///
    /// Entries wholly before the edit must match unchanged; entries wholly
    /// after it must match shifted by `delta`. Whatever lies between the first
    /// mismatch from the front and the last mismatch from the back — plus the
    /// edited text itself — needs restyling. Exact by construction: both
    /// layouts are full parses, so this only bounds the work, never the truth.
    public func changedRange(from old: MarkdownLayout, edit: NSRange, delta: Int) -> NSRange {
        var start = edit.location
        var end = NSMaxRange(edit) + delta

        func widen<T>(_ oldItems: [T], _ newItems: [T], _ range: (T) -> NSRange, _ same: (T, T, Int) -> Bool) {
            // Front: items starting before the edit must be identical.
            var i = 0
            while i < oldItems.count, i < newItems.count,
                  range(newItems[i]).location < edit.location, same(oldItems[i], newItems[i], 0) { i += 1 }
            if i < newItems.count { start = min(start, range(newItems[i]).location) }
            if i < oldItems.count { start = min(start, range(oldItems[i]).location) }
            // Back: items starting after the edit must be identical once shifted.
            var j = 0
            while j < oldItems.count, j < newItems.count {
                let o = oldItems[oldItems.count - 1 - j], n = newItems[newItems.count - 1 - j]
                guard range(o).location >= NSMaxRange(edit), same(o, n, delta) else { break }
                j += 1
            }
            if j < newItems.count { end = max(end, NSMaxRange(range(newItems[newItems.count - 1 - j]))) }
            if j < oldItems.count { end = max(end, NSMaxRange(range(oldItems[oldItems.count - 1 - j])) + delta) }
        }

        widen(old.styles, styles, { $0.range }) { o, n, d in o.style == n.style && o.range.shifted(by: d) == n.range }
        widen(old.markers, markers, { $0.unit }) { o, n, d in
            o.range.shifted(by: d) == n.range && o.unit.shifted(by: d) == n.unit && o.collapsesLine == n.collapsesLine
        }
        widen(old.spellExempt, spellExempt, { $0 }) { o, n, d in o.shifted(by: d) == n }
        widen(old.codeBlocks, codeBlocks, { $0.range }) { o, n, d in
            o.range.shifted(by: d) == n.range && o.body.shifted(by: d) == n.body
        }
        start = max(0, min(start, length))
        end = min(length, max(end, start))
        return NSRange(location: start, length: end - start)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MarkdownLayoutPropertyTests`
Expected: 1 test, 0 failures (about 1 s). A failure message names the seed, step, edit and inserted token — reproduce it in a focused parser test before changing the parser.

- [ ] **Step 5: Commit**

```bash
git add Sources/TVMVCore/MarkdownLayoutDiff.swift Tests/TVMVCoreTests/MarkdownLayoutPropertyTests.swift
git commit -m "Bound restyling to the range where two layouts differ"
```

---

### Task 4: HeadingSlugger

The outline and `#anchor` links must resolve exactly as the web reader's did, so this is a port of `makeSlugger` in `Sources/TVMVCore/Resources/web/boot.js` (lines 70–106). The expected values in the test were produced by running the JS original under node.

**Files:**
- Create: `Sources/TVMVCore/HeadingSlugger.swift`
- Test: `Tests/TVMVCoreTests/HeadingSluggerTests.swift`

**Interfaces:**
- Produces: `public struct HeadingSlugger { init(); static func base(_:) -> String; mutating func slug(_ text: String) -> String }` — one slugger per document pass, headings in order.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TVMVCore

/// Expected values were produced by boot.js's own `makeSlugger` (node).
final class HeadingSluggerTests: XCTestCase {
    func testMatchesTheWebReadersSlugs() {
        var slugger = HeadingSlugger()
        let cases: [(String, String)] = [
            ("Hello World", "hello-world"),
            ("Hello World", "hello-world-1"),
            ("Hello World-1", "hello-world-1-1"),
            ("Hello World", "hello-world-2"),
            ("Ünïcödé Straße", "ünïcödé-straße"),
            ("C++ & Rust!", "c-rust"),
            ("  spaced  out  ", "-spaced-out-"),
            ("emoji 😀 here", "emoji-here"),
            ("日本語 見出し", "日本語-見出し"),
            ("a_b-c", "a_b-c"),
            ("Ⅻ roman ½", "ⅻ-roman-½"),
        ]
        for (title, expected) in cases {
            XCTAssertEqual(slugger.slug(title), expected, title)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HeadingSluggerTests`
Expected: FAIL — `cannot find 'HeadingSlugger' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Swift port of boot.js's GitHub heading-slug algorithm, so the native
/// outline and `#anchor` links resolve exactly as the web reader's did:
/// lowercase; strip everything but letters, numbers, marks, "_", "-", and
/// spaces; spaces become hyphens; runs of hyphens collapse; duplicates get
/// "-1", "-2", … (and a deduped slug is itself taken).
public struct HeadingSlugger {
    private var seen: [String: Int] = [:]

    public init() {}

    public static func base(_ text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            switch scalar.properties.generalCategory {
            // \p{L}, \p{N}, \p{M} — exactly the classes boot.js keeps.
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .nonspacingMark, .spacingMark, .enclosingMark:
                out.unicodeScalars.append(scalar)
            default:
                if scalar == "_" || scalar == "-" { out.unicodeScalars.append(scalar) }
                else if scalar == " " { out.unicodeScalars.append("-") }
            }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out
    }

    public mutating func slug(_ text: String) -> String {
        let s = Self.base(text)
        guard let count = seen[s] else { seen[s] = 0; return s }
        var n = count + 1
        var candidate = "\(s)-\(n)"
        while seen[candidate] != nil { n += 1; candidate = "\(s)-\(n)" }
        seen[s] = n
        seen[candidate] = 0
        return candidate
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HeadingSluggerTests`
Expected: 1 test, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/TVMVCore/HeadingSlugger.swift Tests/TVMVCoreTests/HeadingSluggerTests.swift
git commit -m "Port the heading slug algorithm to Swift"
```

---

### Task 5: EditRules

Pure functions over the text and an `isHidden(i)` predicate (the view supplies one that reads the `.tvmvHidden` attribute):

- Caret never rests strictly inside hidden markup; it passes over it in the direction of travel.
- Never before a hidden line prefix (`# `): typing at a heading's visual start stays in the heading.
- Collapsed whole lines (code fences, setext underlines): forward lands after, backward lands at the end of the previous line.
- One-character deletes landing on hidden markup delete the nearest visible character; backspace after a line prefix removes the prefix; backspace into a collapsed line does nothing.
- `toggleWrap` wraps a non-empty selection in a marker or unwraps it.

**Files:**
- Create: `Sources/TVMVCore/EditRules.swift`
- Test: `Tests/TVMVCoreTests/EditRulesTests.swift`

**Interfaces:**
- Consumes: `MarkdownLayoutParser` (tests only), existing `TextPatcher.Patch`.
- Produces: `public enum EditRules` with `hiddenRun(at:length:isHidden:) -> NSRange`, `snapCaret(_:movingForward:in:isHidden:) -> Int`, `enum DeleteAction { case allow, replace(NSRange), ignore }`, `retargetDelete(_:caret:in:isHidden:) -> DeleteAction`, `toggleWrap(_:marker:in:) -> (patches: [TextPatcher.Patch], selection: NSRange)?`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import TVMVCore

final class EditRulesTests: XCTestCase {
    private let text = "# Title\n\nSome *em* text\n\n```\ncode\n```\nafter\n" as NSString
    private var hidden = IndexSet()
    private var isHidden: (Int) -> Bool { { [hidden] in hidden.contains($0) } }

    override func setUp() {
        hidden = IndexSet()
        for marker in MarkdownLayoutParser.parse(text as String).markers {
            hidden.insert(integersIn: marker.range.location..<NSMaxRange(marker.range))
        }
    }

    private func snap(_ location: Int, forward: Bool) -> Int {
        EditRules.snapCaret(location, movingForward: forward, in: text, isHidden: isHidden)
    }

    private func delete(_ location: Int, caret: Int) -> EditRules.DeleteAction {
        EditRules.retargetDelete(NSRange(location: location, length: 1), caret: caret, in: text, isHidden: isHidden)
    }

    func testCaretNeverRestsBeforeAHiddenHeadingPrefix() {
        XCTAssertEqual(snap(0, forward: true), 2)
        XCTAssertEqual(snap(0, forward: false), 2)
        XCTAssertEqual(snap(1, forward: false), 2)
    }

    func testCaretMayRestAtTheInnerEdgeOfFormatting() {
        let em = text.range(of: "*em*")
        XCTAssertEqual(snap(em.location + 1, forward: true), em.location + 1)
        XCTAssertEqual(snap(NSMaxRange(em) - 1, forward: true), NSMaxRange(em) - 1)
    }

    func testCollapsedFenceLinesArePassedInTheDirectionOfTravel() {
        let fence = text.range(of: "```\ncode").location
        let close = text.range(of: "```\nafter").location
        XCTAssertEqual(snap(fence, forward: true), fence + 4)        // first code line
        XCTAssertEqual(snap(fence + 2, forward: false), fence - 1)   // end of previous line
        XCTAssertEqual(snap(close, forward: true), close + 4)        // after the block
    }

    func testBackspaceAfterAHeadingPrefixRemovesThePrefix() {
        XCTAssertEqual(delete(1, caret: 2), .replace(NSRange(location: 0, length: 2)))
    }

    func testDeletingHiddenMarkupDeletesTheNearestVisibleCharacter() {
        let em = text.range(of: "*em*")
        XCTAssertEqual(delete(NSMaxRange(em) - 1, caret: NSMaxRange(em)),
                       .replace(NSRange(location: NSMaxRange(em) - 2, length: 1)))           // backspace: "m"
        XCTAssertEqual(delete(em.location, caret: em.location),
                       .replace(NSRange(location: em.location + 1, length: 1)))              // forward: "e"
    }

    func testBackspaceIntoACollapsedFenceDoesNothing() {
        let code = text.range(of: "code").location
        XCTAssertEqual(delete(code - 1, caret: code), .ignore)
    }

    func testVisibleDeletesAreUntouched() {
        XCTAssertEqual(delete(10, caret: 11), .allow)
    }

    func testToggleWrapWrapsAndUnwraps() {
        let wrap = EditRules.toggleWrap(NSRange(location: 9, length: 4), marker: "*", in: text)
        XCTAssertEqual(wrap?.patches, [.init(from: 9, to: 9, insert: "*"), .init(from: 13, to: 13, insert: "*")])
        XCTAssertEqual(wrap?.selection, NSRange(location: 10, length: 4))

        let em = text.range(of: "em")
        let unwrap = EditRules.toggleWrap(em, marker: "*", in: text)
        XCTAssertEqual(unwrap?.patches, [.init(from: em.location - 1, to: em.location, insert: ""),
                                         .init(from: NSMaxRange(em), to: NSMaxRange(em) + 1, insert: "")])
        XCTAssertEqual(unwrap?.selection, NSRange(location: em.location - 1, length: 2))

        XCTAssertNil(EditRules.toggleWrap(NSRange(location: 3, length: 0), marker: "*", in: text))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter EditRulesTests`
Expected: FAIL — `cannot find 'EditRules' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Caret and delete behavior around hidden markup, as pure functions of the
/// text and a hidden-character predicate. `isHidden(i)` is true when the
/// character at UTF-16 offset `i` is currently hidden markup.
public enum EditRules {

    /// The maximal run of hidden characters containing offset `i`.
    public static func hiddenRun(at i: Int, length: Int, isHidden: (Int) -> Bool) -> NSRange {
        var start = i, end = i
        while start > 0, isHidden(start - 1) { start -= 1 }
        while end < length, isHidden(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    static func isLineStart(_ i: Int, in text: NSString) -> Bool {
        i == 0 || text.character(at: i - 1) == 10
    }

    /// Where a zero-length caret requested at `location` should rest.
    ///
    /// - Inside a hidden run: pass over it in the direction of travel.
    /// - A run that begins a line (a heading's "# "): always rest after it,
    ///   so typing at a line's visual start stays inside the heading.
    /// - A run that is a whole collapsed line (code fence, setext underline):
    ///   moving forward lands after it; moving back lands at the end of the
    ///   previous line.
    public static func snapCaret(_ location: Int, movingForward: Bool, in text: NSString,
                                 isHidden: (Int) -> Bool) -> Int {
        let length = text.length
        let insideRun = location > 0 && location < length && isHidden(location - 1) && isHidden(location)
        let beforeLinePrefix = location < length && isHidden(location) && isLineStart(location, in: text)
        guard insideRun || beforeLinePrefix else { return location }
        let run = hiddenRun(at: location, length: length, isHidden: isHidden)
        let wholeLine = isLineStart(run.location, in: text)
            && NSMaxRange(run) > run.location && text.character(at: NSMaxRange(run) - 1) == 10
        if wholeLine {
            if movingForward || run.location == 0 { return NSMaxRange(run) }
            return run.location - 1
        }
        if isLineStart(run.location, in: text) { return NSMaxRange(run) }
        return movingForward ? NSMaxRange(run) : run.location
    }

    public enum DeleteAction: Equatable {
        /// Let the text view delete as requested.
        case allow
        /// Delete this range instead.
        case replace(NSRange)
        /// Do nothing.
        case ignore
    }

    /// A one-character delete that lands on hidden markup.
    ///
    /// - Backspace right after a hidden line prefix ("# ") removes the prefix.
    /// - Backspace or forward-delete into a collapsed line does nothing (it
    ///   would join a code block to its neighbor).
    /// - Otherwise the nearest visible character in that direction goes.
    public static func retargetDelete(_ range: NSRange, caret: Int, in text: NSString,
                                      isHidden: (Int) -> Bool) -> DeleteAction {
        guard range.length == 1, isHidden(range.location) else { return .allow }
        let length = text.length
        let run = hiddenRun(at: range.location, length: length, isHidden: isHidden)
        let backward = caret == NSMaxRange(range)
        let wholeLine = isLineStart(run.location, in: text)
            && text.character(at: NSMaxRange(run) - 1) == 10
        if wholeLine { return .ignore }
        if backward && isLineStart(run.location, in: text) { return .replace(run) }
        var target = backward ? run.location - 1 : NSMaxRange(run)
        while target >= 0, target < length, isHidden(target) { target += backward ? -1 : 1 }
        guard target >= 0, target < length else { return .ignore }
        return .replace(NSRange(location: target, length: 1))
    }

    /// Wrap a non-empty selection in `marker` (or unwrap it if it already is
    /// wrapped). Returns the patches (ascending, against the current text) and
    /// the selection afterwards; nil when there is nothing to do.
    public static func toggleWrap(_ selection: NSRange, marker: String, in text: NSString)
        -> (patches: [TextPatcher.Patch], selection: NSRange)? {
        guard selection.length > 0 else { return nil }
        let k = (marker as NSString).length
        let before = NSRange(location: selection.location - k, length: k)
        let after = NSRange(location: NSMaxRange(selection), length: k)
        if before.location >= 0, NSMaxRange(after) <= text.length,
           text.substring(with: before) == marker, text.substring(with: after) == marker {
            return ([.init(from: before.location, to: NSMaxRange(before), insert: ""),
                     .init(from: after.location, to: NSMaxRange(after), insert: "")],
                    NSRange(location: selection.location - k, length: selection.length))
        }
        return ([.init(from: selection.location, to: selection.location, insert: marker),
                 .init(from: NSMaxRange(selection), to: NSMaxRange(selection), insert: marker)],
                NSRange(location: selection.location + k, length: selection.length))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter EditRulesTests`
Expected: 8 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/TVMVCore/EditRules.swift Tests/TVMVCoreTests/EditRulesTests.swift
git commit -m "Define caret and delete rules around hidden markup"
```

---

### Task 6: Reading positions, and ViewerModel hooks for the native view

The native view stores the reading position and bookmark as a character offset under new keys (`readingOffset.<path>`, `bookmarkOffset.<path>`); the web reader's scroll-fraction keys (`readingPosition.<path>`, `bookmark.<path>`) are read as a fallback until the first offset is written. `ViewerModel` gains three things: `rendersPreview` (the native view sets it false so edits stop scheduling web renders), `onExternalTextAdopted` (called when a disk change is adopted), and the native reading-position API.

**Files:**
- Create: `Sources/TVMVCore/ReadingPositionStore.swift`
- Modify: `Sources/TVMVCore/ViewerModel.swift`
- Test: `Tests/TVMVCoreTests/ReadingPositionStoreTests.swift`, `Tests/TVMVCoreTests/ViewerModelNativeTests.swift`

**Interfaces:**
- Produces: `public struct ReadingPositionStore { enum Position: Equatable, Sendable { case offset(Int), fraction(Double) }; init(fileURL:defaults:); var readingPosition: Position?; var bookmark: Position?; func setReadingOffset(_:); func setBookmarkOffset(_:) }`; on `ViewerModel`: `public var rendersPreview: Bool`, `public var onExternalTextAdopted: (@MainActor (String) -> Void)?`, `public var nativeReadingPosition: ReadingPositionStore.Position?`, `public var nativeBookmark: ReadingPositionStore.Position?`, `public func nativeReadingChanged(offset: Int, progress: Double)`, `public func nativeSaveBookmark(offset: Int)`.

- [ ] **Step 1: Write the failing tests**

`Tests/TVMVCoreTests/ReadingPositionStoreTests.swift`:

```swift
import XCTest
@testable import TVMVCore

final class ReadingPositionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private let file = URL(fileURLWithPath: "/tmp/doc.md")

    override func setUp() {
        suite = "ReadingPositionStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testNothingStoredIsNil() {
        let store = ReadingPositionStore(fileURL: file, defaults: defaults)
        XCTAssertNil(store.readingPosition)
        XCTAssertNil(store.bookmark)
    }

    func testLegacyFractionsAreReadUntilAnOffsetIsWritten() {
        defaults.set(0.4, forKey: "readingPosition./tmp/doc.md")
        defaults.set(0.7, forKey: "bookmark./tmp/doc.md")
        let store = ReadingPositionStore(fileURL: file, defaults: defaults)
        XCTAssertEqual(store.readingPosition, .fraction(0.4))
        XCTAssertEqual(store.bookmark, .fraction(0.7))

        store.setReadingOffset(1234)
        store.setBookmarkOffset(99)
        XCTAssertEqual(store.readingPosition, .offset(1234))
        XCTAssertEqual(store.bookmark, .offset(99))
    }
}
```

`Tests/TVMVCoreTests/ViewerModelNativeTests.swift`:

```swift
import XCTest
@testable import TVMVCore

@MainActor
final class ViewerModelNativeTests: XCTestCase {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvmv-native-\(UUID().uuidString).md")
        try contents.data(using: .utf8)!.write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            let path = url.standardizedFileURL.path
            for key in ["readingOffset.", "bookmarkOffset.", "readingPosition.", "bookmark."] {
                UserDefaults.standard.removeObject(forKey: key + path)
            }
        }
        return url
    }

    func testExternalChangeIsHandedToTheNativeView() async throws {
        let url = try tempFile("one\n")
        let model = ViewerModel(text: "one\n", fileURL: url)
        var adopted: [String] = []
        model.onExternalTextAdopted = { adopted.append($0) }
        try "two\n".write(to: url, atomically: true, encoding: .utf8)
        await model.reload()
        XCTAssertEqual(adopted, ["two\n"])
        XCTAssertEqual(model.text, "two\n")
    }

    func testExternalChangeWithUnsavedEditsIsNotAdopted() async throws {
        let url = try tempFile("one\n")
        let model = ViewerModel(text: "one\n", fileURL: url)
        model.rendersPreview = false
        var adopted: [String] = []
        model.onExternalTextAdopted = { adopted.append($0) }
        model.textEdited("mine\n")
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        await model.reload()
        XCTAssertEqual(adopted, [])
        XCTAssertEqual(model.text, "mine\n")
        XCTAssertTrue(model.externalChangePending)
    }

    func testNativeReadingPositionAndBookmark() throws {
        let url = try tempFile("x\n")
        let model = ViewerModel(text: "x\n", fileURL: url)
        XCTAssertNil(model.nativeReadingPosition)
        model.nativeReadingChanged(offset: 120, progress: 0.25)
        XCTAssertEqual(model.nativeReadingPosition, .offset(120))
        XCTAssertEqual(model.readingProgress, 0.25)

        XCTAssertFalse(model.hasBookmark)
        model.nativeSaveBookmark(offset: 7)
        XCTAssertTrue(model.hasBookmark)
        XCTAssertEqual(model.nativeBookmark, .offset(7))
        XCTAssertTrue(ViewerModel(text: "x\n", fileURL: url).hasBookmark, "an offset bookmark survives reopening")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ReadingPositionStoreTests|ViewerModelNativeTests"`
Expected: FAIL — `cannot find 'ReadingPositionStore' in scope` / `value of type 'ViewerModel' has no member 'onExternalTextAdopted'`.

- [ ] **Step 3: Write the store**

`Sources/TVMVCore/ReadingPositionStore.swift`:

```swift
import Foundation

/// Per-file reading position and bookmark for the native view, stored as a
/// UTF-16 character offset (survives edits and resizes). Older builds stored
/// a scroll fraction under other keys; those are read as a fallback until the
/// first offset is written.
public struct ReadingPositionStore {
    public enum Position: Equatable, Sendable {
        case offset(Int)
        /// Legacy scroll fraction, 0...1.
        case fraction(Double)
    }

    private let defaults: UserDefaults
    private let path: String

    public init(fileURL: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.path = fileURL.standardizedFileURL.path
    }

    private var readingOffsetKey: String { "readingOffset.\(path)" }
    private var bookmarkOffsetKey: String { "bookmarkOffset.\(path)" }
    private var legacyReadingKey: String { "readingPosition.\(path)" }
    private var legacyBookmarkKey: String { "bookmark.\(path)" }

    public var readingPosition: Position? { position(offsetKey: readingOffsetKey, legacyKey: legacyReadingKey) }
    public var bookmark: Position? { position(offsetKey: bookmarkOffsetKey, legacyKey: legacyBookmarkKey) }

    public func setReadingOffset(_ offset: Int) { defaults.set(offset, forKey: readingOffsetKey) }
    public func setBookmarkOffset(_ offset: Int) { defaults.set(offset, forKey: bookmarkOffsetKey) }

    private func position(offsetKey: String, legacyKey: String) -> Position? {
        if let offset = defaults.object(forKey: offsetKey) as? Int { return .offset(offset) }
        if let fraction = defaults.object(forKey: legacyKey) as? Double { return .fraction(fraction) }
        return nil
    }
}
```

- [ ] **Step 4: Apply the ViewerModel changes**

```diff
diff --git a/Sources/TVMVCore/ViewerModel.swift b/Sources/TVMVCore/ViewerModel.swift
index c357ebd..ebed59f 100644
--- a/Sources/TVMVCore/ViewerModel.swift
+++ b/Sources/TVMVCore/ViewerModel.swift
@@ -35,6 +35,14 @@ public final class ViewerModel: ObservableObject {
     /// the Mac shell leaves it nil and uses save() explicitly.
     public var onTextChange: (@MainActor (String) -> Void)?
 
+    /// False for the macOS native view: it renders the text itself, so edits
+    /// must not schedule web-preview renders.
+    public var rendersPreview = true
+
+    /// The file changed on disk and was adopted (there were no unsaved
+    /// edits). The macOS native view replaces its text with it.
+    public var onExternalTextAdopted: (@MainActor (String) -> Void)?
+
     private var lastSavedText: String
     private var controller: MarkdownWebController?
     private var editorBridge: EditorBridge?
@@ -95,6 +103,7 @@ public final class ViewerModel: ObservableObject {
             let path = url.standardizedFileURL.path
             readingProgress = UserDefaults.standard.double(forKey: "readingPosition.\(path)")
             hasBookmark = UserDefaults.standard.object(forKey: "bookmark.\(path)") != nil
+                || UserDefaults.standard.object(forKey: "bookmarkOffset.\(path)") != nil
         }
     }
 
@@ -189,13 +198,15 @@ public final class ViewerModel: ObservableObject {
         // fires objectWillChange and invalidates the window per keystroke batch.
         let dirty = (newText != lastSavedText)
         if dirty != isDirty { isDirty = dirty }
-        previewNeedsRender = true
-        renderDebounce?.cancel()
-        let work = DispatchWorkItem { [weak self] in
-            Task { @MainActor [weak self] in await self?.renderAfterEdit() }
+        if rendersPreview {
+            previewNeedsRender = true
+            renderDebounce?.cancel()
+            let work = DispatchWorkItem { [weak self] in
+                Task { @MainActor [weak self] in await self?.renderAfterEdit() }
+            }
+            renderDebounce = work
+            DispatchQueue.main.asyncAfter(deadline: .now() + renderDebounceDelay, execute: work)
         }
-        renderDebounce = work
-        DispatchQueue.main.asyncAfter(deadline: .now() + renderDebounceDelay, execute: work)
         onTextChange?(newText)
     }
 
@@ -347,6 +358,28 @@ public final class ViewerModel: ObservableObject {
         if let readingKey { UserDefaults.standard.set(value, forKey: readingKey) }
     }
 
+    // MARK: Native reading position (macOS native view)
+
+    private var readingStore: ReadingPositionStore? {
+        fileURL.map { ReadingPositionStore(fileURL: $0) }
+    }
+
+    /// Where to open the document: a character offset, or a legacy fraction.
+    public var nativeReadingPosition: ReadingPositionStore.Position? { readingStore?.readingPosition }
+    public var nativeBookmark: ReadingPositionStore.Position? { readingStore?.bookmark }
+
+    /// The native view scrolled: remember the top character and show progress.
+    public func nativeReadingChanged(offset: Int, progress: Double) {
+        readingStore?.setReadingOffset(offset)
+        let value = min(1, max(0, progress))
+        if abs(value - readingProgress) > 0.001 { readingProgress = value }
+    }
+
+    public func nativeSaveBookmark(offset: Int) {
+        readingStore?.setBookmarkOffset(offset)
+        hasBookmark = true
+    }
+
     public func saveBookmark() async {
         guard let controller else { return }
         let ratio = min(1, max(0, await controller.getScrollRatio()))
@@ -488,6 +521,7 @@ public final class ViewerModel: ObservableObject {
         }
         text = decoded
         lastSavedText = decoded
+        onExternalTextAdopted?(decoded)
         if isEditing, let bridge = editorBridge {
             // Programmatic replacement: fresh history so ⌘Z can't resurrect
             // the pre-reload text. The resulting textChanged echo is a no-op
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "ReadingPositionStoreTests|ViewerModelNativeTests|ViewerModelEditingTests"`
Expected: all pass (the existing `ViewerModelEditingTests` must still pass — `rendersPreview` defaults to true).

- [ ] **Step 6: Commit**

```bash
git add Sources/TVMVCore/ReadingPositionStore.swift Sources/TVMVCore/ViewerModel.swift Tests/TVMVCoreTests/ReadingPositionStoreTests.swift Tests/TVMVCoreTests/ViewerModelNativeTests.swift
git commit -m "Give the model hooks for a native document view"
```

---

### Task 7: The native view — theme, styler, DocumentTextView

`DocumentTextView` is an `NSTextView` created with `usingTextLayoutManager: false` (TextKit 1 — TextKit 2 has no null-glyph hook). A private `Hooks` object is its delegate, its layout manager's delegate and its text storage's delegate:

- **Storage `didProcessEditing`** records each character edit as a `TextPatcher.Patch` (sent to the model) and tracks the unchanged prefix/suffix since the last layout.
- **`textDidChange`** (outside `processEditing`) re-parses and restyles the changed range. Skipped while IME text is marked; the committing edit triggers it.
- **The layout-manager hook** turns `.tvmvHidden` characters into null glyphs. Attribute changes regenerate glyphs — verified by `testRevealShowsOneSpanUntilTheSelectionLeaves`.
- **Selection and delete hooks** apply `EditRules`; the spelling hook consults `.tvmvNoSpell`.
- **Undo** goes to a private `UndoManager`. The window's document undo manager belongs to a `DocumentGroup(viewing:)` document that cannot be saved — the same reason `CodeMirrorEditorPane` sandboxed its undo.

**Files:**
- Create: `Sources/tvmv/NativeTheme.swift`, `Sources/tvmv/DocumentStyler.swift`, `Sources/tvmv/DocumentTextView.swift`
- Test: `Tests/tvmvTests/DocumentTextViewTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 3, 5; `TextPatcher.Patch`; `AppSettings`, `RGBAColor`.
- Produces:
  - `struct NativeTheme: Equatable`:
    - init: `init(bodyFamily:monoFamily:size:measure:fullWidth:dark:)`, plus `@MainActor init(settings:dark:)`.
    - fonts and colors: `body`, `mono`, `ink`, `inkSoft`, `muted`, `accent`, `paper`, `paperDeep`.
    - layout: `columnWidth: CGFloat?`, `padding`.
    - styling: `base`, `headingFont(_:)`, `codeParagraph(first:last:)`, `chromeColor: RGBAColor`.
  - Attribute keys `.tvmvHidden`, `.tvmvNoSpell`, `.tvmvLink`.
  - `enum DocumentStyler { static func apply(_:to:in:theme:isRevealed:) }`.
  - `final class DocumentTextView: NSTextView`:
    - creation and content: `static func make()`, `load(_:)`, `replace(_:with:)`.
    - state: `layout`, `theme`, `showAllMarkup`, `revealing`.
    - reveal: `reveal(_:)`, `toggleRevealMarkup(_:)`, `toggleShowMarkdown(_:)`.
    - formatting: `toggleBold(_:)`, `toggleItalic(_:)`.
    - queries: `isHidden(_:)`, `isSpellExempt(_:)`, `link(at:)`.
    - callbacks: `onEdit: ((TextPatcher.Patch, Int) -> Void)?`, `onLayout: ((MarkdownLayout) -> Void)?`, `onFollowLink: ((String) -> Void)?`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import AppKit
import TVMVCore
@testable import tvmv

@MainActor
final class DocumentTextViewTests: XCTestCase {
    private var window: NSWindow!
    private var view: DocumentTextView!
    private var patches: [TextPatcher.Patch] = []
    private let doc = "# Title\n\nSome **bold** and *em* text with [a link](https://example.com) and recieve.\n\n```swift\nlet wrongg = 1\n```\nafter\n"

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        view = DocumentTextView.make()
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = view
        window.contentView!.addSubview(scroll)
        patches = []
        view.onEdit = { [unowned self] patch, _ in patches.append(patch) }
        view.load(doc)
    }

    private func pump(_ seconds: Double = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Whether the glyph for character `index` is a null (hidden) glyph.
    private func glyphHidden(_ index: Int) -> Bool {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        return lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: index)).contains(.null)
    }

    private var ns: NSString { view.string as NSString }

    func testMarkupIsHiddenAndTheTextUntouched() {
        let bold = ns.range(of: "**bold**")
        XCTAssertTrue(glyphHidden(0))
        XCTAssertTrue(glyphHidden(bold.location))
        XCTAssertFalse(glyphHidden(bold.location + 2))
        XCTAssertEqual(view.string, doc)
    }

    func testColumnIsCenteredWithoutChangingTheViewWidth() {
        // Regression: centering via the inset must not make the view grow to
        // fit it (that loop pushed the column off to the right).
        let column = view.theme.columnWidth!
        view.setFrameSize(NSSize(width: 1400, height: 600))
        XCTAssertEqual(view.frame.width, 1400)
        XCTAssertEqual(view.textContainer!.size.width, column, accuracy: 1)
        XCTAssertEqual(view.textContainerInset.width, (1400 - column) / 2, accuracy: 1)

        view.setFrameSize(NSSize(width: 500, height: 600))
        XCTAssertEqual(view.frame.width, 500)
        XCTAssertEqual(view.textContainerInset.width, view.theme.padding, accuracy: 1)
        XCTAssertEqual(view.textContainer!.size.width, 500 - 2 * view.theme.padding, accuracy: 1)
    }

    func testCaretSnapsPastTheHeadingPrefix() {
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(view.selectedRange().location, 2)
    }

    func testRevealShowsOneSpanUntilTheSelectionLeaves() {
        let bold = ns.range(of: "**bold**")
        view.setSelectedRange(NSRange(location: bold.location + 3, length: 0))
        view.reveal(true)
        XCTAssertFalse(glyphHidden(bold.location))
        XCTAssertTrue(glyphHidden(0), "other spans stay hidden")

        view.setSelectedRange(NSRange(location: ns.range(of: "after").location, length: 0))
        pump()
        XCTAssertTrue(glyphHidden(bold.location))
        XCTAssertFalse(view.revealing)
    }

    func testShowAllMarkup() {
        view.showAllMarkup = true
        XCTAssertFalse(glyphHidden(0))
        view.showAllMarkup = false
        XCTAssertTrue(glyphHidden(0))
    }

    func testBackspaceAfterHiddenDelimiterDeletesTheVisibleCharacterAndUndoes() {
        view.isEditable = true
        window.makeFirstResponder(view)
        let em = ns.range(of: "*em*")
        view.setSelectedRange(NSRange(location: NSMaxRange(em), length: 0))
        view.deleteBackward(nil)
        pump()
        XCTAssertTrue(view.string.contains("*e* text"))
        XCTAssertEqual(patches.last, .init(from: NSMaxRange(em) - 2, to: NSMaxRange(em) - 1, insert: ""))
        view.undoManager?.undo()
        pump()
        XCTAssertEqual(view.string, doc)
    }

    func testTypedFormattingRendersImmediately() {
        view.isEditable = true
        let end = ns.range(of: "after").location + 5
        view.insertText(" *new*", replacementRange: NSRange(location: end, length: 0))
        pump()
        let em = ns.range(of: "*new*")
        XCTAssertTrue(glyphHidden(em.location))
        XCTAssertTrue(glyphHidden(NSMaxRange(em) - 1))
        XCTAssertFalse(glyphHidden(em.location + 1))
    }

    func testLinkUnderPoint() {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        let text = ns.range(of: "a link")
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: text.location + 1, length: 1), actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
        let point = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        XCTAssertEqual(view.link(at: point), "https://example.com")
    }

    func testSpellingExemptions() {
        // The live squiggles come from the system spell checker, which does
        // not run under XCTest; check the exemption the delegate consults.
        XCTAssertTrue(view.isSpellExempt(ns.range(of: "wrongg")))
        XCTAssertTrue(view.isSpellExempt(ns.range(of: "https://example.com")))
        XCTAssertFalse(view.isSpellExempt(ns.range(of: "recieve")))
        XCTAssertFalse(view.isSpellExempt(ns.range(of: "a link")))
    }

    func testLargeDocumentsParseOffTheMainThreadAndApply() {
        var big = ""
        while big.utf16.count < 300_000 { big += doc + "\n" }
        view.isEditable = true
        view.load(big)
        let before = view.layout.markers.count
        view.insertText("**x** ", replacementRange: NSRange(location: 9, length: 0))
        XCTAssertEqual(view.layout.markers.count, before, "not applied synchronously")
        let deadline = Date().addingTimeInterval(5)
        while view.layout.markers.count == before, Date() < deadline { pump() }
        XCTAssertEqual(view.layout.markers.count, before + 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DocumentTextViewTests`
Expected: FAIL — `cannot find 'DocumentTextView' in scope`.

- [ ] **Step 3: Write the theme**

`Sources/tvmv/NativeTheme.swift`:

```swift
import AppKit
import TVMVCore

extension NSAttributedString.Key {
    /// Markup hidden by the layout-manager delegate (null glyphs).
    static let tvmvHidden = NSAttributedString.Key("tvmvHidden")
    /// Exempt from spelling and grammar checking.
    static let tvmvNoSpell = NSAttributedString.Key("tvmvNoSpell")
    /// Link destination; clicks follow it when read-only or with ⌘.
    static let tvmvLink = NSAttributedString.Key("tvmvLink")
}

/// Fonts, colors and measure for the native view: the paper & ink palette
/// from app.css, expressed as AppKit values.
struct NativeTheme: Equatable {
    var body: NSFont
    var mono: NSFont
    var ink: NSColor
    var inkSoft: NSColor
    var muted: NSColor
    var accent: NSColor
    var paper: NSColor
    var paperDeep: NSColor
    /// Text column width in points; nil means full width.
    var columnWidth: CGFloat?
    /// Minimum horizontal padding either side of the column (app.css --tvmv-pad).
    var padding: CGFloat = 68

    init(bodyFamily: String, monoFamily: String, size: CGFloat, measure: Double, fullWidth: Bool, dark: Bool) {
        body = NSFont(name: bodyFamily, size: size)
            ?? NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        mono = NSFont(name: monoFamily, size: size * 0.86)
            ?? .monospacedSystemFont(ofSize: size * 0.86, weight: .regular)
        func hex(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        if dark {
            paper = hex(0x181410); paperDeep = hex(0x221C16); ink = hex(0xECE3D3)
            inkSoft = hex(0xCBB89B); muted = hex(0x9C876A); accent = hex(0xE2693B)
        } else {
            paper = hex(0xFBF8F2); paperDeep = hex(0xF4EFE3); ink = hex(0x2A1810)
            inkSoft = hex(0x5A3D2A); muted = hex(0x8A7359); accent = hex(0xB83F12)
        }
        let zero = ("0" as NSString).size(withAttributes: [.font: body]).width
        columnWidth = fullWidth ? nil : CGFloat(measure) * zero
    }

    var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.3
        p.paragraphSpacing = body.pointSize * 0.6
        return p
    }

    /// Code lines: no gaps between lines; room above the first line and
    /// below the last for the block background.
    func codeParagraph(first: Bool, last: Bool) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        p.paragraphSpacingBefore = first ? body.pointSize * 0.7 : 0
        p.paragraphSpacing = last ? body.pointSize * 1.1 : 0
        return p
    }

    static var collapsedParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = 0.01
        p.maximumLineHeight = 0.01
        return p
    }

    var base: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: ink, .paragraphStyle: paragraphStyle]
    }

    /// app.css heading scale: h1 2.0em … h6 0.85em.
    func headingFont(_ level: Int) -> NSFont {
        let scale: [CGFloat] = [2.0, 1.5, 1.28, 1.1, 0.95, 0.85]
        let font = body.withSize(body.pointSize * scale[max(1, min(level, 6)) - 1])
        return NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
}

extension NativeTheme {
    /// The theme for the current settings. `dark` is the resolved appearance
    /// (Settings' light/dark, or the system's when set to auto).
    @MainActor
    init(settings: AppSettings, dark: Bool) {
        self.init(bodyFamily: settings.bodyFont, monoFamily: settings.monoFont,
                  size: CGFloat(settings.baseSize), measure: settings.measure,
                  fullWidth: settings.fullWidth, dark: dark)
    }

    /// Window-chrome tint: the paper color lightened, as the web reader did.
    var chromeColor: RGBAColor {
        let c = paper.usingColorSpace(.sRGB) ?? paper
        return RGBAColor(red: Double(c.redComponent), green: Double(c.greenComponent),
                         blue: Double(c.blueComponent)).blended(fraction: 0.16, of: .white)
    }
}
```

- [ ] **Step 4: Write the styler**

`Sources/tvmv/DocumentStyler.swift`:

```swift
import AppKit
import TVMVCore

/// Applies a `MarkdownLayout` to a text storage, limited to one range.
enum DocumentStyler {
    /// - Parameter isRevealed: whether a reveal unit's markup is currently shown.
    static func apply(_ layout: MarkdownLayout, to storage: NSTextStorage, in range: NSRange,
                      theme: NativeTheme, isRevealed: (NSRange) -> Bool) {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return }
        func clip(_ r: NSRange) -> NSRange? {
            let c = NSIntersectionRange(r, range)
            return c.length > 0 ? c : nil
        }
        func addTrait(_ trait: NSFontTraitMask, _ r: NSRange) {
            storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                let font = (value as? NSFont) ?? theme.body
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
            }
        }

        storage.beginEditing()
        storage.setAttributes(theme.base, range: range)
        for run in layout.styles {
            guard let r = clip(run.range) else { continue }
            switch run.style {
            case .heading(let level):
                storage.addAttribute(.font, value: theme.headingFont(level), range: r)
            case .emphasis:
                addTrait(.italicFontMask, r)
            case .strong:
                addTrait(.boldFontMask, r)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .code:
                storage.addAttributes([.font: theme.mono, .backgroundColor: theme.paperDeep], range: r)
            case .codeBlock:
                storage.addAttribute(.font, value: theme.mono, range: r)
            case .link(let url), .autolink(let url):
                storage.addAttributes([.foregroundColor: theme.accent, .tvmvLink: url,
                                       .underlineStyle: NSUnderlineStyle.single.rawValue], range: r)
            case .html, .image:
                storage.addAttributes([.font: theme.mono, .foregroundColor: theme.muted], range: r)
            }
        }
        for block in layout.codeBlocks where block.body.length > 0 {
            guard NSIntersectionRange(block.body, range).length > 0 else { continue }
            let text = storage.string as NSString
            var line = text.lineRange(for: NSRange(location: block.body.location, length: 0))
            while line.location < NSMaxRange(block.body) {
                let first = line.location <= block.body.location
                let last = NSMaxRange(line) >= NSMaxRange(block.body)
                if let r = clip(line) {
                    storage.addAttribute(.paragraphStyle, value: theme.codeParagraph(first: first, last: last), range: r)
                }
                guard NSMaxRange(line) < text.length else { break }
                line = text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))
            }
        }
        for marker in layout.markers {
            guard let r = clip(marker.range), !isRevealed(marker.unit) else { continue }
            storage.addAttribute(.tvmvHidden, value: true, range: r)
            if marker.collapsesLine {
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.1),
                                       .paragraphStyle: NativeTheme.collapsedParagraph], range: r)
            }
        }
        for exempt in layout.spellExempt {
            if let r = clip(exempt) { storage.addAttribute(.tvmvNoSpell, value: true, range: r) }
        }
        storage.endEditing()
    }
}
```

- [ ] **Step 5: Write the view**

`Sources/tvmv/DocumentTextView.swift`:

```swift
import AppKit
import TVMVCore

/// The native reader/editor: one TextKit 1 text view in which Markdown
/// renders in place with its markup hidden.
///
/// - Hiding: markers carry `.tvmvHidden`; the layout-manager delegate turns
///   those characters into null glyphs. The text itself never changes.
/// - Parsing: after each edit the whole text is re-parsed (synchronously up
///   to `syncParseLimit`, otherwise off the main thread, latest wins), and
///   only the range where the old and new layouts differ is restyled.
/// - Reveal: double-click or ⌘' shows the markup of the span(s) under the
///   selection until Esc or the selection leaves them; ⌥⌘M shows all markup.
final class DocumentTextView: NSTextView {
    static let syncParseLimit = 64 * 1024

    private(set) var layout = MarkdownLayout()
    var theme: NativeTheme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16,
                                         measure: 80, fullWidth: false, dark: false) {
        didSet { applyTheme() }
    }
    var showAllMarkup = false {
        didSet { restyle(NSRange(location: 0, length: textStorage?.length ?? 0)) }
    }
    /// True after a reveal request, until the selection leaves every revealed unit.
    private(set) var revealing = false
    private var revealedUnits: [NSRange] = []

    /// Every text change, as a patch against the previous text plus the new length.
    var onEdit: ((TextPatcher.Patch, Int) -> Void)?
    /// A new layout was applied (headings may have changed).
    var onLayout: ((MarkdownLayout) -> Void)?
    /// A link was activated (read-only click, or ⌘-click while editing).
    var onFollowLink: ((String) -> Void)?

    /// Private undo stack: the window's document undo manager belongs to a
    /// DocumentGroup(viewing:) document that can't be saved, and registering
    /// edits there triggers autosave alerts (see CodeMirrorEditorPane's history).
    private let documentUndo = UndoManager()
    override var undoManager: UndoManager? { documentUndo }

    private let hooks = Hooks()
    private var parseGeneration = 0
    /// Characters at the start and end of the text unchanged since `layout` was computed.
    private var unchangedPrefix = Int.max
    private var unchangedSuffix = Int.max

    static func make() -> DocumentTextView {
        let view = DocumentTextView(usingTextLayoutManager: false)   // TextKit 1: null glyphs
        view.configure()
        return view
    }

    private func configure() {
        hooks.view = self
        delegate = hooks
        layoutManager?.delegate = hooks
        textStorage?.delegate = hooks
        isRichText = false
        allowsUndo = true
        isEditable = false
        isSelectable = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = true
        textContainer?.widthTracksTextView = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        applyTheme()
    }

    // MARK: Content

    /// Replace the whole text (initial load, external reload). Not undoable.
    func load(_ text: String) {
        guard let storage = textStorage else { return }
        hooks.loading = true
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        hooks.loading = false
        documentUndo.removeAllActions()
        layout = MarkdownLayoutParser.parse(text)
        unchangedPrefix = .max; unchangedSuffix = .max
        restyle(NSRange(location: 0, length: storage.length))
        onLayout?(layout)
    }

    /// Replace `range` through the undoable edit path.
    @discardableResult
    func replace(_ range: NSRange, with string: String) -> Bool {
        guard shouldChangeText(in: range, replacementString: string) else { return false }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
        return true
    }

    // MARK: Parse + restyle

    /// Called by the storage delegate for every character edit.
    fileprivate func recordEdit(editedRange: NSRange, delta: Int) {
        guard let storage = textStorage else { return }
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        let oldLength = storage.length - delta
        unchangedPrefix = min(unchangedPrefix, oldRange.location)
        unchangedSuffix = min(unchangedSuffix, oldLength - NSMaxRange(oldRange))
        let insert = (storage.string as NSString).substring(with: editedRange)
        onEdit?(.init(from: oldRange.location, to: NSMaxRange(oldRange), insert: insert), storage.length)
    }

    /// Re-parse after edits (called from textDidChange, outside processEditing).
    fileprivate func textChanged() {
        guard let storage = textStorage, !hasMarkedText() else { return }
        let text = storage.string
        let old = layout
        let prefix = min(unchangedPrefix, old.length), suffix = min(unchangedSuffix, old.length - prefix)
        let edit = NSRange(location: prefix, length: old.length - suffix - prefix)
        let delta = storage.length - old.length
        parseGeneration += 1
        let generation = parseGeneration
        if storage.length <= Self.syncParseLimit {
            applyParsed(MarkdownLayoutParser.parse(text), from: old, edit: edit, delta: delta, generation: generation)
        } else {
            Task {
                let new = await Task.detached(priority: .userInitiated) { MarkdownLayoutParser.parse(text) }.value
                self.applyParsed(new, from: old, edit: edit, delta: delta, generation: generation)
            }
        }
    }

    /// Install a parse result unless a newer edit has superseded it (latest wins).
    private func applyParsed(_ new: MarkdownLayout, from old: MarkdownLayout, edit: NSRange, delta: Int, generation: Int) {
        guard generation == parseGeneration else { return }
        unchangedPrefix = .max; unchangedSuffix = .max
        let changed = new.changedRange(from: old, edit: edit, delta: delta)
        layout = new
        updateRevealedUnits()
        restyle(changed)
        onLayout?(new)
    }

    func restyle(_ range: NSRange) {
        guard let storage = textStorage else { return }
        let units = revealedUnits
        let all = showAllMarkup
        DocumentStyler.apply(layout, to: storage, in: range, theme: theme) { unit in
            all || units.contains(unit)
        }
        typingAttributes = theme.base
        needsDisplay = true
    }

    private func applyTheme() {
        backgroundColor = theme.paper
        insertionPointColor = theme.ink
        selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.18)]
        layoutColumn()
        restyle(NSRange(location: 0, length: textStorage?.length ?? 0))
    }

    /// Center a column of `theme.columnWidth` (or fill the width) with at least `theme.padding` each side.
    func layoutColumn() {
        guard let container = textContainer else { return }
        let available = max(200, bounds.width - 2 * theme.padding)
        let width = min(theme.columnWidth ?? available, available)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textContainerInset = NSSize(width: max(theme.padding, (bounds.width - width) / 2), height: 36)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutColumn()
    }

    // MARK: Reveal

    /// Show the markup of the unit(s) enclosing the selection (on), or hide it again (off).
    func reveal(_ on: Bool) {
        setRevealedUnits(on ? unitsEnclosingSelection() : [])
    }

    func toggleShowAllMarkup() { showAllMarkup.toggle() }

    /// Units containing the selection. A caret at a unit's end counts as
    /// inside it — unless the unit ends with a newline (a block): then the
    /// caret is already on the next line.
    func unitsEnclosingSelection() -> [NSRange] {
        guard let storage = textStorage else { return [] }
        let text = storage.string as NSString
        let selection = selectedRange()
        return layout.revealUnits.filter { unit in
            guard unit.encloses(selection) else { return false }
            if selection.length == 0, selection.location == NSMaxRange(unit), unit.length > 0,
               text.character(at: NSMaxRange(unit) - 1) == 10 { return false }
            return true
        }
    }

    private func setRevealedUnits(_ units: [NSRange]) {
        revealing = !units.isEmpty
        guard units != revealedUnits else { return }
        let touched = (units + revealedUnits).reduce(nil as NSRange?) { acc, r in acc.map { NSUnionRange($0, r) } ?? r }
        revealedUnits = units
        if let touched { restyle(touched) }
    }

    /// Selection moved: a reveal ends once the selection leaves every revealed unit.
    fileprivate func selectionChanged() {
        guard revealing else { return }
        let current = Set(unitsEnclosingSelection())
        if !revealedUnits.contains(where: current.contains) { setRevealedUnits([]) }
    }

    /// After a re-parse, revealed units are re-found around the selection
    /// (their ranges moved with the edit).
    fileprivate func updateRevealedUnits() {
        if revealing { setRevealedUnits(unitsEnclosingSelection()) }
    }

    /// Code, URLs and other exempt ranges never get spelling or grammar marks.
    func isSpellExempt(_ range: NSRange) -> Bool {
        guard let storage = textStorage else { return false }
        let range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        var exempt = false
        storage.enumerateAttribute(.tvmvNoSpell, in: range) { value, _, stop in
            if value != nil { exempt = true; stop.pointee = true }
        }
        return exempt
    }

    func isHidden(_ index: Int) -> Bool {
        guard let storage = textStorage, index >= 0, index < storage.length else { return false }
        return storage.attribute(.tvmvHidden, at: index, effectiveRange: nil) != nil
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, !isEditable || event.modifierFlags.contains(.command),
           let url = link(at: convert(event.locationInWindow, from: nil)) {
            onFollowLink?(url)
            return
        }
        super.mouseDown(with: event)
        if event.clickCount == 2 { reveal(true) }
    }

    func link(at point: NSPoint) -> String? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let index = lm.characterIndex(for: p, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < storage.length else { return nil }
        return storage.attribute(.tvmvLink, at: index, effectiveRange: nil) as? String
    }

    override func cancelOperation(_ sender: Any?) {
        if revealing { reveal(false) } else { super.cancelOperation(sender) }
    }

    @objc func toggleRevealMarkup(_ sender: Any?) { reveal(!revealing) }
    @objc func toggleShowMarkdown(_ sender: Any?) { toggleShowAllMarkup() }
    @objc func toggleBold(_ sender: Any?) { wrapSelection("**") }
    @objc func toggleItalic(_ sender: Any?) { wrapSelection("*") }

    func wrapSelection(_ marker: String) {
        guard isEditable, let storage = textStorage,
              let result = EditRules.toggleWrap(selectedRange(), marker: marker, in: storage.string as NSString)
        else { return }
        undoManager?.beginUndoGrouping()
        for patch in result.patches.reversed() {
            replace(NSRange(location: patch.from, length: patch.to - patch.from), with: patch.insert)
        }
        undoManager?.endUndoGrouping()
        setSelectedRange(result.selection)
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let visible = lm.characterRange(
            forGlyphRange: lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: tc),
            actualGlyphRange: nil)
        theme.paperDeep.setFill()
        for block in layout.codeBlocks where NSIntersectionRange(block.range, visible).length > 0 && block.body.length > 0 {
            let glyphs = lm.glyphRange(forCharacterRange: block.body, actualCharacterRange: nil)
            var box = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            box.origin.x = textContainerOrigin.x - 12
            box.size.width = tc.containerSize.width + 24
            box.origin.y += textContainerOrigin.y - 8
            box.size.height += 16
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        }
    }

    // MARK: Delegates

    /// Delegate object for the view, its layout manager and its text storage.
    private final class Hooks: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate, NSTextStorageDelegate {
        weak var view: DocumentTextView?
        var loading = false

        func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                         range: NSRange, changeInLength delta: Int) {
            guard mask.contains(.editedCharacters), !loading else { return }
            view?.recordEdit(editedRange: range, delta: delta)
        }

        func textDidChange(_ notification: Notification) { view?.textChanged() }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view else { return }
            view.typingAttributes = view.theme.base
            view.selectionChanged()
        }

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                      toCharacterRange new: NSRange) -> NSRange {
            guard let view, !view.showAllMarkup, new.length == 0, let storage = view.textStorage else { return new }
            let location = EditRules.snapCaret(new.location, movingForward: new.location >= old.location,
                                               in: storage.string as NSString, isHidden: view.isHidden)
            return NSRange(location: location, length: 0)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString string: String?) -> Bool {
            guard let view, !view.showAllMarkup, string == "", let storage = view.textStorage else { return true }
            let caret = view.selectedRange().location
            switch EditRules.retargetDelete(range, caret: caret, in: storage.string as NSString, isHidden: view.isHidden) {
            case .allow:
                return true
            case .ignore:
                return false
            case .replace(let target):
                // Not re-entrantly: this runs inside the text view's own edit.
                DispatchQueue.main.async {
                    if view.replace(target, with: "") {
                        view.setSelectedRange(NSRange(location: target.location, length: 0))
                    }
                }
                return false
            }
        }

        func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range: NSRange) -> Int {
            view?.isSpellExempt(range) == true ? 0 : value
        }

        func layoutManager(_ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                           properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                           characterIndexes: UnsafePointer<Int>, font: NSFont,
                           forGlyphRange glyphRange: NSRange) -> Int {
            guard let storage = lm.textStorage else { return 0 }
            var props = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
            var changed = false
            var run = NSRange(location: NSNotFound, length: 0)
            var runHidden = false
            for i in 0..<glyphRange.length {
                let ci = characterIndexes[i]
                if !NSLocationInRange(ci, run) {
                    runHidden = storage.attribute(.tvmvHidden, at: ci, effectiveRange: &run) != nil
                }
                if runHidden, !props[i].contains(.controlCharacter) {
                    props[i] = .null
                    changed = true
                }
            }
            guard changed else { return 0 }
            lm.setGlyphs(glyphs, properties: props, characterIndexes: characterIndexes, font: font,
                         forGlyphRange: glyphRange)
            return glyphRange.length
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DocumentTextViewTests`
Expected: 10 tests, 0 failures (the large-document test takes about 1–2 s).

- [ ] **Step 7: Commit**

```bash
git add Sources/tvmv/NativeTheme.swift Sources/tvmv/DocumentStyler.swift Sources/tvmv/DocumentTextView.swift Tests/tvmvTests/DocumentTextViewTests.swift
git commit -m "Render and edit Markdown in place in a native text view"
```

---

### Task 8: Host the native view in the window

This task swaps the window's detail area to the native view and moves outline, find, bookmarks, links, markup commands and print onto it. Print and Save as PDF keep the existing web pipeline: `PrintRenderer` renders the current text, unsaved edits included, in an offscreen web view, waits for `renderComplete` (highlighting, KaTeX and Mermaid are done), then runs the print panel as a sheet on the document window. `CodeMirrorEditorPane.swift` and `MarkdownWebView.swift` are deleted: nothing on macOS uses them, and iOS has its own wrappers in `ios/Sources/`. The external-change banner stays until the merge plan replaces it.

**Bug the prototype hit — keep the fix:** SwiftUI hosts the scroll view with Auto Layout, which turns the text view's autoresizing mask into constraints when the view is inserted. Creating the text view with a placeholder width (800 pt) while its clip view was 0 pt wide produced a permanent 800 pt surplus: the app logged a 1,819 pt text view in a 1,019 pt clip view, and the column was centered off-screen. `makeScrollView` therefore creates the text view at `scroll.contentSize`. A unit test pins that invariant. The full Auto Layout sequence did not reproduce under XCTest, so the screenshot check in Task 10 is the end-to-end proof.

**Files:**
- Create: `Sources/tvmv/NativeDocumentView.swift`, `Sources/tvmv/PrintRenderer.swift`
- Modify: `Sources/TVMVCore/PreviewBridge.swift`, `Sources/tvmv/ViewerWindow.swift`, `Sources/tvmv/ViewerCommands.swift`
- Delete: `Sources/tvmv/CodeMirrorEditorPane.swift`, `Sources/tvmv/MarkdownWebView.swift`
- Test: `Tests/tvmvTests/NativeDocumentViewTests.swift`

**Interfaces:**
- Consumes: Tasks 4, 6, 7; `PreviewCoordinator`, `MarkdownWebController`, `MarkdownWebViewCallbacks`, `WebResources`, `AssetSchemeHandler`, `renderHTML`.
- Produces:
  - `@MainActor final class NativeDocumentController`:
    - attachment: `attach(_:)`, `textView`, `window`.
    - scrolling: `scrollTo(anchor:)`, `scrollTo(offset:)`, `scrollTo(fraction:)`, `restore(_:)`, `topVisibleOffset()`, `progress`.
    - commands: `showFind()`, `toggleRevealMarkup()`, `toggleShowMarkdown()`, `bold()`, `italic()`, `follow(_:documentURL:)`.
    - helper: `static outline(from:)`.
  - `struct NativeDocumentView: NSViewRepresentable`, with `static makeScrollView(theme:) -> (NSScrollView, DocumentTextView)`.
  - `PrintRenderer.print(text:title:documentDirectory:sheetWindow:)`.
  - `ViewerCommands` gains `revealMarkup`, `showMarkdown`, `bold`, `italic` and `isEditing`.

- [ ] **Step 1: Write the failing tests**

```swift
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter NativeDocumentViewTests`
Expected: FAIL — `cannot find 'NativeDocumentView' in scope`.

- [ ] **Step 3: Write the wrapper and controller**

`Sources/tvmv/NativeDocumentView.swift`:

```swift
import TVMVCore
import SwiftUI
import AppKit

/// Imperative handle on a window's native text view: outline jumps,
/// bookmarks, reading position, find, and the markup commands.
@MainActor
final class NativeDocumentController {
    private(set) weak var textView: DocumentTextView?

    func attach(_ view: DocumentTextView) { textView = view }

    var window: NSWindow? { textView?.window }

    /// Scroll so the heading whose slug is `anchor` sits at the top.
    func scrollTo(anchor: String) {
        guard let view = textView else { return }
        var slugger = HeadingSlugger()
        for heading in view.layout.headings where slugger.slug(heading.title) == anchor {
            scrollTo(offset: heading.range.location)
            return
        }
    }

    /// UTF-16 offset of the first character at the top of the visible area.
    func topVisibleOffset() -> Int {
        guard let view = textView, let lm = view.layoutManager, let tc = view.textContainer,
              (view.string as NSString).length > 0 else { return 0 }
        // One point below the edge: exactly at it, the line above (whose
        // fragment includes its paragraph spacing) would claim the point.
        let point = NSPoint(x: 0, y: max(0, view.visibleRect.minY - view.textContainerOrigin.y + 1))
        return lm.characterIndexForGlyph(at: lm.glyphIndex(for: point, in: tc))
    }

    func scrollTo(offset: Int) {
        guard let view = textView, let lm = view.layoutManager, let tc = view.textContainer else { return }
        let length = (view.string as NSString).length
        guard length > 0 else { return }
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: min(max(0, offset), length - 1), length: 1),
                                   actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        view.scroll(NSPoint(x: 0, y: max(0, rect.minY + view.textContainerOrigin.y)))
    }

    func scrollTo(fraction: Double) {
        guard let view = textView, let clip = view.enclosingScrollView?.contentView, let tc = view.textContainer else { return }
        view.layoutManager?.ensureLayout(for: tc)
        let maxY = max(0, view.bounds.height - clip.bounds.height)
        view.scroll(NSPoint(x: 0, y: maxY * min(1, max(0, fraction))))
    }

    func restore(_ position: ReadingPositionStore.Position?) {
        switch position {
        case .offset(let offset): scrollTo(offset: offset)
        case .fraction(let fraction): scrollTo(fraction: fraction)
        case nil: break
        }
    }

    /// Scroll progress, 0...1.
    var progress: Double {
        guard let view = textView, let clip = view.enclosingScrollView?.contentView else { return 0 }
        let maxY = view.bounds.height - clip.bounds.height
        return maxY > 0 ? min(1, max(0, clip.bounds.minY / maxY)) : 0
    }

    func showFind() {
        guard let view = textView else { return }
        view.window?.makeFirstResponder(view)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(item)
    }

    func toggleRevealMarkup() { textView?.toggleRevealMarkup(nil) }
    func toggleShowMarkdown() { textView?.toggleShowMarkdown(nil) }
    func bold() { textView?.toggleBold(nil) }
    func italic() { textView?.toggleItalic(nil) }

    /// Follow a link from the document: `#slug` scrolls to that heading; a
    /// URL with a scheme opens externally; anything else is a path relative
    /// to the document's folder.
    func follow(_ link: String, documentURL: URL?) {
        if link.hasPrefix("#") {
            let anchor = String(link.dropFirst())
            scrollTo(anchor: anchor.removingPercentEncoding ?? anchor)
        } else if let url = URL(string: link), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else if let folder = documentURL?.deletingLastPathComponent() {
            let path = String(link.split(separator: "#", maxSplits: 1).first ?? "")
            NSWorkspace.shared.open(folder.appendingPathComponent(path.removingPercentEncoding ?? path))
        }
    }

    /// Outline entries for a layout, with the web reader's slugs.
    static func outline(from layout: MarkdownLayout) -> [OutlineItem] {
        var slugger = HeadingSlugger()
        return layout.headings.map { OutlineItem(level: $0.level, title: $0.title, anchor: slugger.slug($0.title)) }
    }
}

/// The macOS document surface: a scroll view hosting the native
/// reader/editor, wired to the window's `ViewerModel`.
struct NativeDocumentView: NSViewRepresentable {
    @ObservedObject var model: ViewerModel
    let controller: NativeDocumentController
    let theme: NativeTheme
    let isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A scroll view hosting a fresh text view.
    static func makeScrollView(theme: NativeTheme) -> (NSScrollView, DocumentTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = DocumentTextView.make()
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        // Exactly the clip view's size: under Auto Layout the autoresizing
        // mask becomes constraints, and any mismatch here would persist.
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        scroll.documentView = view
        view.theme = theme
        scroll.backgroundColor = theme.paper
        return (scroll, view)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = Self.makeScrollView(theme: theme)

        let model = self.model
        let controller = self.controller
        view.onEdit = { patch, length in model.editorTextPatched([patch], expectedLength: length) }
        view.onLayout = { layout in
            let outline = NativeDocumentController.outline(from: layout)
            if outline != model.outline { model.outline = outline }
        }
        view.onFollowLink = { [weak controller] link in controller?.follow(link, documentURL: model.fileURL) }
        view.load(model.text)
        controller.attach(view)

        // A file change adopted with no unsaved edits: replace the text, keep the place.
        model.onExternalTextAdopted = { [weak view, weak controller] text in
            guard let view, let controller else { return }
            let top = controller.topVisibleOffset()
            view.load(text)
            controller.scrollTo(offset: top)
        }

        context.coordinator.observeScrolling(scroll.contentView, model: model, controller: controller)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view, weak scroll] in
            guard let view, let scroll else { return }
            FileHandle.standardError.write(Data("DIAG scroll \(scroll.contentSize.width) view \(view.frame.width) inset \(view.textContainerInset.width) container \(view.textContainer!.size.width)\n".utf8))
        }
        DispatchQueue.main.async {
            controller.restore(model.nativeReadingPosition)
            context.coordinator.restored = true
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? DocumentTextView else { return }
        if view.theme != theme {
            view.theme = theme
            scroll.backgroundColor = theme.paper
        }
        if view.isEditable != isEditable {
            view.isEditable = isEditable
            if isEditable { view.window?.makeFirstResponder(view) }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// Saves the reading position as the user scrolls (debounced).
    @MainActor
    final class Coordinator {
        var restored = false
        private var observer: NSObjectProtocol?
        private var pending: Task<Void, Never>?

        func observeScrolling(_ clip: NSClipView, model: ViewerModel, controller: NativeDocumentController) {
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self, weak model, weak controller] _ in
                MainActor.assumeIsolated {
                    guard let self, self.restored, let model, let controller else { return }
                    self.pending?.cancel()
                    self.pending = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
                        model.nativeReadingChanged(offset: controller.topVisibleOffset(), progress: controller.progress)
                    }
                }
            }
        }

        func stop() {
            pending?.cancel()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
```

- [ ] **Step 4: Let print target a given window**

```diff
diff --git a/Sources/TVMVCore/PreviewBridge.swift b/Sources/TVMVCore/PreviewBridge.swift
index 2f26f7f..a502eb6 100644
--- a/Sources/TVMVCore/PreviewBridge.swift
+++ b/Sources/TVMVCore/PreviewBridge.swift
@@ -304,7 +304,9 @@ public final class MarkdownWebController {
 #if os(macOS)
     // MARK: Print (surfaces Save-as-PDF)
 
-    public func printDocument(jobTitle: String? = nil) {
+    /// - Parameter sheetWindow: the window to attach the print panel to;
+    ///   defaults to the web view's own window.
+    public func printDocument(jobTitle: String? = nil, sheetWindow: NSWindow? = nil) {
         guard let webView else { return }
         let printInfo = NSPrintInfo.shared
         let operation = webView.printOperation(with: printInfo)
@@ -318,7 +320,7 @@ public final class MarkdownWebController {
         }
         operation.showsPrintPanel = true
         operation.showsProgressPanel = true
-        if let window = webView.window {
+        if let window = sheetWindow ?? webView.window {
             operation.runModal(
                 for: window,
                 delegate: nil,
```

- [ ] **Step 5: Write the print renderer**

`Sources/tvmv/PrintRenderer.swift`:

```swift
import TVMVCore
import AppKit
import WebKit

/// Print and Save as PDF through the existing web pipeline (cmark HTML plus
/// the built-in theme). An offscreen web view, in a window that is never
/// shown, renders the current text — unsaved edits included — and once
/// enrichment (highlighting, KaTeX, Mermaid) has finished the print panel
/// runs as a sheet on the document window.
@MainActor
final class PrintRenderer {
    /// The print in flight; the next print replaces it.
    private static var current: PrintRenderer?

    private let coordinator: PreviewCoordinator
    private let webView: WKWebView
    private let offscreen: NSWindow

    static func print(text: String, title: String?, documentDirectory: URL?, sheetWindow: NSWindow?) {
        current = PrintRenderer(text: text, title: title, documentDirectory: documentDirectory, sheetWindow: sheetWindow)
    }

    private init(text: String, title: String?, documentDirectory: URL?, sheetWindow: NSWindow?) {
        offscreen = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 1000),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        coordinator = PreviewCoordinator(callbacks: MarkdownWebViewCallbacks())
        webView = WKWebView(frame: offscreen.contentView!.bounds,
                            configuration: coordinator.makeConfiguration(appWebDir: WebResources.baseURL,
                                                                         docDir: documentDirectory))
        offscreen.contentView!.addSubview(webView)
        let controller = coordinator.attach(webView)
        var printed = false
        coordinator.callbacks.onReady = {
            Task { @MainActor in
                await controller.setContent(bodyHTML: renderHTML(text),
                                            docBaseHref: "\(AssetSchemeHandler.scheme)://doc/")
                await controller.applyStyle(json: AppSettings.shared.styleJSON)
            }
        }
        coordinator.callbacks.onRenderComplete = { [weak self] in
            guard !printed else { return }
            printed = true
            controller.printDocument(jobTitle: title, sheetWindow: sheetWindow)
            self?.webView.configuration.userContentController.removeScriptMessageHandler(forName: "tvmv")
        }
    }
}
```

- [ ] **Step 6: Add the commands**

```diff
diff --git a/Sources/tvmv/ViewerCommands.swift b/Sources/tvmv/ViewerCommands.swift
index 5df2947..a4bd941 100644
--- a/Sources/tvmv/ViewerCommands.swift
+++ b/Sources/tvmv/ViewerCommands.swift
@@ -2,7 +2,7 @@ import TVMVCore
 import SwiftUI
 
 /// Per-window menu actions. The focused viewer window publishes these via
-/// `focusedSceneValue`, so menu commands (Find, Print, Reload, Toggle Outline)
+/// `focusedSceneValue`, so menu commands (Find, Print, Reload, Toggle Outline, markup)
 /// act only on the frontmost window — not on every open window.
 struct ViewerCommands {
     var find: () -> Void
@@ -11,10 +11,18 @@ struct ViewerCommands {
     var toggleOutline: () -> Void
     var toggleEditing: () -> Void
     var save: () -> Void
+    /// ⌘': show the markup of the span under the selection (again: hide it).
+    var revealMarkup: () -> Void
+    /// ⌥⌘M: show all markup.
+    var showMarkdown: () -> Void
+    var bold: () -> Void
+    var italic: () -> Void
     /// Enables ⌘S: there are unsaved edits and a file to write to.
     var canSave: Bool
     /// Enables ⌘E: the document has a file URL to save back to.
     var canEdit: Bool
+    /// Enables ⌘B/⌘I, which write markup into the text.
+    var isEditing: Bool
 }
 
 struct ViewerCommandsKey: FocusedValueKey {
@@ -64,6 +72,21 @@ struct ViewerMenuCommands: Commands {
                 .keyboardShortcut("r", modifiers: .command)
                 .disabled(commands == nil)
         }
+        CommandGroup(replacing: .textFormatting) {
+            Button("Bold") { commands?.bold() }
+                .keyboardShortcut("b", modifiers: .command)
+                .disabled(commands?.isEditing != true)
+            Button("Italic") { commands?.italic() }
+                .keyboardShortcut("i", modifiers: .command)
+                .disabled(commands?.isEditing != true)
+            Divider()
+            Button("Reveal Markup Here") { commands?.revealMarkup() }
+                .keyboardShortcut("'", modifiers: .command)
+                .disabled(commands == nil)
+            Button("Show Markdown") { commands?.showMarkdown() }
+                .keyboardShortcut("m", modifiers: [.command, .option])
+                .disabled(commands == nil)
+        }
         CommandGroup(replacing: .printItem) {
             Button("Print…") { commands?.printDocument() }
                 .keyboardShortcut("p", modifiers: .command)
```

- [ ] **Step 7: Rewrite the window**

Replace `Sources/tvmv/ViewerWindow.swift` with:

```swift
import TVMVCore
import SwiftUI
import AppKit

struct ViewerWindow: View {
    // The document is consumed in init (seeds the model); storing it here would
    // keep a second copy of the full text alive for the window's lifetime.
    let fileURL: URL?

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model: ViewerModel
    /// Imperative handle on the native view: outline jumps, bookmarks, find, markup commands.
    @State private var native = NativeDocumentController()

    @State private var columns: NavigationSplitViewVisibility = .automatic
    @State private var selection: OutlineItem.ID?

    init(document: MarkdownDocument, fileURL: URL?) {
        self.fileURL = fileURL
        _model = StateObject(wrappedValue: Self.makeModel(document, fileURL))
    }

    private static func makeModel(_ document: MarkdownDocument, _ fileURL: URL?) -> ViewerModel {
        let model = ViewerModel(
            text: document.text, fileURL: fileURL,
            encoding: document.encodingUsed, lineEnding: document.lineEndingUsed)
        model.rendersPreview = false   // the native view renders the text itself
        return model
    }

    /// Settings' light/dark, or the system appearance when set to auto.
    private var theme: NativeTheme {
        let dark = settings.theme == .auto ? colorScheme == .dark : settings.theme == .dark
        return NativeTheme(settings: settings, dark: dark)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(model.outline, selection: $selection) { item in
                Text(item.title)
                    .padding(.leading, CGFloat((item.level - 1) * 12))
                    .lineLimit(1)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 240)
            .scrollContentBackground(model.chromeColor == nil ? .automatic : .hidden)
            .background(model.chromeColor.map {
                Color(red: $0.red, green: $0.green, blue: $0.blue)
            } ?? .clear)
        } detail: {
            NativeDocumentView(model: model, controller: native, theme: theme, isEditable: model.isEditing)
                .overlay(alignment: .top) {
                    if model.externalChangePending { externalChangeBanner }
                }
                .overlay(alignment: .bottom) {
                    if model.errorMessage != nil { errorBanner }
                }
        }
        .background { WindowChrome(color: model.chromeColor) }
        .background { WindowCloseGuard(
            needsFlow: { model.isDirty || model.isEditing },
            flush: { await model.flushEditorText() },
            isDirty: { model.isDirty },
            save: { model.save(); return !model.isDirty }
        ) }
        .navigationTitle(fileURL?.lastPathComponent ?? "Untitled")
        // Dirty indicator. Deliberately NOT window.isDocumentEdited: marking a
        // DocumentGroup(viewing:) window "edited" drags in AppKit's autosave
        // machinery, which can't save this document and alerts about it.
        .navigationSubtitle(model.isDirty ? "Edited" : "")
        .toolbar {
            ToolbarItemGroup {
                Text("\(Int((model.readingProgress * 100).rounded()))%")
                    .monospacedDigit()
                    .help("Reading progress")
                Button { model.nativeSaveBookmark(offset: native.topVisibleOffset()) } label: {
                    Image(systemName: "bookmark")
                }
                .help("Bookmark current place")
                Button { native.restore(model.nativeBookmark) } label: {
                    Image(systemName: "bookmark.fill")
                }
                .disabled(!model.hasBookmark)
                .help("Go to bookmark")
            }
        }
        .onChange(of: selection) { _, new in
            if let new, let item = model.outline.first(where: { $0.id == new }) {
                native.scrollTo(anchor: item.anchor)
            }
        }
        .onChange(of: theme.paper, initial: true) { model.chromeColor = theme.chromeColor }
        .onAppear {
            columns = settings.showOutline ? .all : .detailOnly
            model.startWatching()
        }
        .onDisappear { model.stopWatching() }
        .alert("Save Failed", isPresented: Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.saveError ?? "")
        }
        // Publish this window's command actions to the menu only while it is the
        // focused scene — so Find/Print/Reload/Toggle-Outline hit just this window.
        .focusedSceneValue(\.viewerCommands, ViewerCommands(
            find: { native.showFind() },
            printDocument: {
                PrintRenderer.print(text: model.text,
                                    title: fileURL?.deletingPathExtension().lastPathComponent,
                                    documentDirectory: fileURL?.deletingLastPathComponent(),
                                    sheetWindow: native.window)
            },
            reload: { Task { await model.reload() } },
            toggleOutline: { columns = (columns == .detailOnly) ? .all : .detailOnly },
            toggleEditing: { model.toggleEditing() },
            save: { Task { await model.flushAndSave() } },
            revealMarkup: { native.toggleRevealMarkup() },
            showMarkdown: { native.toggleShowMarkdown() },
            bold: { native.bold() },
            italic: { native.italic() },
            canSave: (model.isDirty || model.isEditing) && fileURL != nil,
            canEdit: fileURL != nil,
            isEditing: model.isEditing
        ))
    }

    private var errorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            Text(model.errorMessage ?? "")
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .padding(8)
    }

    private var externalChangeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("File changed on disk")
                .font(.caption)
            Spacer()
            Button("Reload (discards edits)") {
                Task { await model.discardAndReload() }
            }
            .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .padding(8)
    }
}

/// Paints the host NSWindow's background so the theme color extends past the
/// content into the window chrome — including the title bar (made transparent so
/// it shows the window background) and the area behind the sidebar. Chrome text
/// (title, sidebar, traffic lights) is flipped light/dark for legibility.
private struct WindowChrome: NSViewRepresentable {
    var color: RGBAColor?
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        let color = color
        DispatchQueue.main.async {
            guard let w = nsView.window else { return }
            if let c = color {
                w.titlebarAppearsTransparent = true   // show the window bg in the title bar
                w.backgroundColor = NSColor(srgbRed: c.red, green: c.green,
                                            blue: c.blue, alpha: c.alpha)
                w.appearance = NSAppearance(named: c.luminance < 0.6 ? .darkAqua : .aqua)
            } else {
                w.titlebarAppearsTransparent = false
                w.backgroundColor = .windowBackgroundColor
                w.appearance = nil
            }
        }
    }
}
```

- [ ] **Step 8: Delete the retired views**

```bash
git rm Sources/tvmv/CodeMirrorEditorPane.swift Sources/tvmv/MarkdownWebView.swift
```

- [ ] **Step 9: Build and run the tests**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` — expected: no errors.
Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "NativeDocumentViewTests|DocumentTextViewTests|WindowCloseGuardTests"`
Expected: all pass.

- [ ] **Step 10: Commit**

```bash
git add -A Sources/tvmv Sources/TVMVCore/PreviewBridge.swift Tests/tvmvTests/NativeDocumentViewTests.swift
git commit -m "Host the native document view in the macOS window"
```

---

### Task 9: Settings and README

The editor-pane font/size settings and Custom CSS leave the macOS Settings window. `AppSettings` keeps the properties: iOS uses the editor ones, and Linux has its own settings.

**Files:**
- Modify: `Sources/tvmv/SettingsView.swift`, `README.md`

- [ ] **Step 1: Replace `Sources/tvmv/SettingsView.swift`**

```swift
import TVMVCore
import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    private let families = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            Picker("Body font", selection: $settings.bodyFont) {
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            Picker("Code font", selection: $settings.monoFont) {
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            Stepper(value: $settings.baseSize, in: 8...48, step: 1) {
                Text("Base size: \(Int(settings.baseSize)) pt")
            }
            Toggle("Full width", isOn: $settings.fullWidth)
            if !settings.fullWidth {
                Stepper(value: $settings.measure, in: 40...120, step: 2) {
                    Text("Measure: \(Int(settings.measure)) ch")
                }
            }
            Picker("Theme", selection: $settings.theme) {
                ForEach(AppSettings.Theme.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(20)
        .frame(width: 400)
    }
}
```

- [ ] **Step 2: Update the README**

```diff
diff --git a/README.md b/README.md
index a8d64c8..1ccf26f 100644
--- a/README.md
+++ b/README.md
@@ -8,7 +8,8 @@ A native Markdown viewer and editor for macOS, iOS and Linux. Opens `.md` files
 in real windows and renders GitHub-Flavored Markdown (via cmark-gfm) with a warm
 "paper & ink" reading theme, syntax highlighting, KaTeX math, and Mermaid
 diagrams. Select & copy, find-in-page (with match count), an outline sidebar,
-a CodeMirror editor with live preview, live reload on file change, print /
+editing (on macOS in place, in the rendered document; on iOS and Linux in a
+CodeMirror editor with live preview), live reload on file change, print /
 Save-as-PDF, and font/size/measure/theme settings. Fully offline — all assets
 are vendored.
 
@@ -53,6 +54,12 @@ button to save a place and the adjacent button to jump back to it. On iOS these
 actions are in the percentage menu. Reading positions and bookmarks are app
 data; they do not modify the Markdown file.
 
+On macOS you edit the document where you read it: press ⌘E and type. Markdown
+renders as you write — type `*word*` and it turns italic — and the markup stays
+hidden. To see or change it, double-click a formatted span or press ⌘' (Esc, or
+moving away, hides it again); ⌥⌘M shows all the Markdown. ⌘B and ⌘I format a
+selection. Spelling and grammar are the system's, and skip code and URLs.
+
 Design spec and implementation plan live in `docs/superpowers/`.
 
 ## QuickLook
@@ -225,7 +232,11 @@ gresource bundles with no plugin API.
 Out of the box TVMV wears its built-in "paper & ink" theme, which has taste. If
 you don't, you can override it with your own CSS — TVMV won't judge.
 
-Open **Settings (⌘,) → Custom CSS → Choose…** and pick a `.css` file. TVMV injects
+Custom CSS applies on Linux. The macOS app now renders documents natively and
+does not load custom CSS (styling options will return in another form); its
+print and Save as PDF use the built-in theme.
+
+Open **Settings (Ctrl+,) → Custom CSS → Choose…** and pick a `.css` file. TVMV injects
 it after the built-in theme (overriding it), tints the window chrome — sidebar,
 window, and title bar — to a slightly-lightened version of your background color,
 and **live-reloads** as you edit the file. *Reset to default* goes back to the
```

- [ ] **Step 3: Build**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/tvmv/SettingsView.swift README.md
git commit -m "Drop the editor-pane and custom-CSS settings on macOS"
```

---

### Task 10: Performance gates, full suite, and the hands-on check

**Files:**
- Modify: `Tests/TVMVCoreTests/PerformanceTests.swift`

- [ ] **Step 1: Add the layout gates**

```diff
diff --git a/Tests/TVMVCoreTests/PerformanceTests.swift b/Tests/TVMVCoreTests/PerformanceTests.swift
index 7da83fd..c15ddef 100644
--- a/Tests/TVMVCoreTests/PerformanceTests.swift
+++ b/Tests/TVMVCoreTests/PerformanceTests.swift
@@ -87,6 +87,25 @@ final class PerformanceTests: XCTestCase {
         }
     }
 
+    /// The native view's per-edit work: a full layout parse (runs off the
+    /// main thread above 64 KB) and the diff that bounds the restyle (main thread).
+    func testLayoutParsePerformance1MB() throws {
+        try XCTSkipUnless(perfEnabled, "set TVMV_PERF=1 to run performance gates")
+        let doc = Self.fixture(megabytes: 1)
+        measure { _ = MarkdownLayoutParser.parse(doc) }
+    }
+
+    func testLayoutDiffPerformance1MB() throws {
+        try XCTSkipUnless(perfEnabled, "set TVMV_PERF=1 to run performance gates")
+        let doc = Self.fixture(megabytes: 1) as NSString
+        let edit = NSRange(location: doc.length / 2, length: 0)
+        let old = MarkdownLayoutParser.parse(doc as String)
+        let new = MarkdownLayoutParser.parse(doc.replacingCharacters(in: edit, with: "x"))
+        var changed = NSRange()
+        measure { changed = new.changedRange(from: old, edit: edit, delta: 1) }
+        XCTAssertLessThan(changed.length, 1_000, "the restyle stays local to the edit")
+    }
+
     func testThumbnailBoundedReadOnLargeFile() throws {
         // Always-on: the thumbnail path must stay O(bounded) however large the
         // file is. 20 MB in, bounded lines out, quickly.
```

- [ ] **Step 2: Run the gates**

Run: `env TVMV_PERF=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "PerformanceTests/testLayout"`
Expected: both pass. Debug-build reference from the prototype:
- Parse: about 0.20 s/MB. It runs off the main thread above 64 KB.
- Diff: about 0.005 s/MB, with the changed range under 1,000 characters.
- Release builds are roughly 2× faster for the parse and 20× faster for the diff.

- [ ] **Step 3: Run the full suite**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with"`
Expected: every bundle line reads `0 failures`. The prototype counted 114 TVMVCoreTests (6 performance gates skipped) and 23 tvmvTests.

- [ ] **Step 4: Run the debug app on the showcase without installing it**

```bash
cp Fixtures/showcase.md /tmp/tvmv-check.md
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
./.build/debug/tvmv /tmp/tvmv-check.md
```

Do not run `build/bundle.fish` for this; it installs into `/Applications`.

- [ ] **Step 5: Do the manual check and note each result in the PR description**

1. **Layout:** the text column is centered with margins on both sides; resize the window and it stays centered. The Task 8 bug showed as the column pushed right and clipped.
2. **Rendering:** headings, bold, italic, strikethrough, inline code, links and code blocks render with no visible markup. Lists, quotes, tables and math still show as source — they are later plans.
3. **Revealing markup:**
   - Double-click **bold**: its `**` appears. Esc hides it again.
   - ⌘' inside a code block shows its fences.
   - ⌥⌘M toggles all markup.
4. **Editing (⌘E):**
   - Type `*word*` and it renders italic.
   - Click at the start of a heading and type: the text joins the heading.
   - Backspace right after italic text deletes the letter, not the `*`.
   - ⌘B and ⌘I wrap a selection.
   - ⌘Z undoes.
   - ⌘S saves, and the file on disk changed as expected.
5. **Spelling:** misspell a word in prose and one inside `` `code` ``. Only the prose one gets the red underline. Edit ▸ Spelling and Grammar is present and works.
6. **Outline and links:** clicking an outline entry scrolls to it. A `#heading` link follows on click while read-only, and with ⌘-click while editing.
7. **Reading position:** scroll, quit, reopen: the same place. The bookmark buttons save and return.
8. **External change:** while read-only, `echo "appended" >> /tmp/tvmv-check.md` shows up in place.
9. **Find:** ⌘F opens the find bar and finds text.
10. **Print:** ⌘P previews the document with the built-in theme, math and diagrams rendered. Save as PDF produces non-blank pages.
11. **Input methods:** type Japanese with the Kotoeri input method inside an italic word — composition looks normal and the result is correct.
12. **VoiceOver:** ⌘F5, then read a paragraph containing bold text. It reads the words without the asterisks.

- [ ] **Step 6: Commit**

```bash
git add Tests/TVMVCoreTests/PerformanceTests.swift
git commit -m "Gate the native layout's parse and diff performance"
```

---

## Known limitations carried by this plan

These are deliberate, and recorded in the spec or deferred to later plans:

- **Find matches the source text**, so a search for `*` can land on hidden markup. Searching only visible text needs a custom `NSTextFinderClient`.
- **Lists, quotes, checkboxes and images** still show their Markdown source (plan 2). So do math, Mermaid, HTML blocks and front matter (plan 3), and tables (plan 4).
- **The external-change banner remains** while there are unsaved edits; the three-way merge replaces it (plan 5).
- **A large document opens with a synchronous full parse:** about 0.1 s/MB in release builds.
- **An emphasis that spans a hard line break shows its delimiters** instead of hiding them. This is safe, and covered by the hard-break segment test.
- **Deferred from spec build steps 1–2:**
  - ⌘K (wrap a selection as a link). It needs a URL prompt.
  - A golden snapshot corpus of layouts. Focused parser tests plus the 1,800-edit property test stand in for it here.
  - List continuation and list/quote prefix removal. They arrive with list rendering in plan 2.

