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
    /// Newlines inside top-level paragraphs that are soft line breaks: the
    /// paragraph reflows across them, so they lay out as spaces.
    public var softBreaks: [Int] = []
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
