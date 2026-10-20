import Foundation

/// Review comments and suggested edits, stored in the Markdown file itself.
///
/// CriticMarkup anchors mark *what* a thread is about and a GFM footnote holds
/// the thread:
///
///     The {==cache==}[^rv-k3f9] is {~~lazy~>eager~~}[^rv-p2x7].
///
///     [^rv-k3f9]: @ulf 2026-10-14: True for autosave too?
///         @claude 2026-10-14: No.
///     [^rv-p2x7]: @claude 2026-10-14 suggestion: Avoids the stall.
///
/// Only `rv-` footnotes belong to review; every other footnote is left alone.
/// Ranges are UTF-16 offsets, the unit `TextPatcher` and the text system use.
///
/// Parsing never throws: a hand-edited file degrades into `problems`, so the
/// UI can still show everything that does parse. This file depends on
/// Foundation only, so the QuickLook build can compile it beside
/// `MarkdownRenderer.swift`; the edit operations live in
/// `ReviewOperations.swift`.
public enum ReviewMarkup {

    // MARK: Model

    public enum AnchorKind: String, Sendable, CaseIterable {
        case highlight, insertion, deletion, substitution, point

        /// Insertions, deletions and substitutions are accepted or rejected;
        /// highlights and points are resolved.
        public var isSuggestion: Bool {
            switch self {
            case .insertion, .deletion, .substitution: return true
            case .highlight, .point: return false
            }
        }
    }

    public struct Anchor: Equatable, Sendable {
        public var id: String
        public var kind: AnchorKind
        /// Everything from the opening delimiter through the `[^id]` ref.
        public var range: Range<Int>
        /// The text between the delimiters (`old~>new` for a substitution);
        /// empty, at the ref, for a point comment.
        public var inner: Range<Int>
        /// Substitution only: the two sides of `~>`.
        public var old: Range<Int>?
        public var new: Range<Int>?
        /// The `[^id]` ref. For a point comment this is the whole anchor.
        public var ref: Range<Int>

        public init(id: String, kind: AnchorKind, range: Range<Int>, inner: Range<Int>,
                    old: Range<Int>? = nil, new: Range<Int>? = nil, ref: Range<Int>) {
            self.id = id
            self.kind = kind
            self.range = range
            self.inner = inner
            self.old = old
            self.new = new
            self.ref = ref
        }
    }

    public enum EntryKind: String, Sendable {
        case comment, suggestion
    }

    /// One `@author YYYY-MM-DD[ suggestion]: text` line of a thread, plus any
    /// continuation lines that are not entries themselves.
    public struct Entry: Equatable, Sendable {
        /// Without the leading `@`; empty when the line is not in entry form.
        public var author: String
        /// `YYYY-MM-DD` as written; empty when the line is not in entry form.
        public var date: String
        public var kind: EntryKind
        /// Continuation lines join with "\n", their indent stripped.
        public var body: String
        public var range: Range<Int>

        public init(author: String, date: String, kind: EntryKind, body: String, range: Range<Int>) {
            self.author = author
            self.date = date
            self.kind = kind
            self.body = body
            self.range = range
        }
    }

    public struct Thread: Equatable, Sendable {
        public var id: String
        /// The whole definition block, including its final newline if any.
        public var range: Range<Int>
        public var entries: [Entry]

        public init(id: String, range: Range<Int>, entries: [Entry]) {
            self.id = id
            self.range = range
            self.entries = entries
        }
    }

    public enum Problem: Equatable, Sendable {
        /// A thread definition no anchor refers to.
        case orphanThread(id: String, range: Range<Int>)
        /// An anchor whose id has no thread definition.
        case danglingAnchor(id: String, range: Range<Int>)
        /// An opening delimiter with no closer in its block, or a stray closer.
        case unbalanced(range: Range<Int>)
        /// Anchors under one id mix comment kinds and suggestion kinds.
        case mixedKinds(id: String)
        /// A second definition for an id; Markdown readers show the first.
        case duplicateThread(id: String, range: Range<Int>)
        /// A thread line that is not `@author YYYY-MM-DD[ suggestion]: text`.
        case malformedEntry(id: String, range: Range<Int>)
    }

    /// Everything review-related in one document, against the text it came from.
    public struct Review: Equatable, Sendable {
        public let text: String
        public let anchors: [Anchor]
        public let threads: [Thread]
        public let problems: [Problem]
        /// Fenced code and `$$` math blocks, from the opening line through the
        /// closing one: markup inside is literal text.
        public let literalBlocks: [Range<Int>]
        /// Inline code spans outside anchors, backticks included.
        public let literalSpans: [Range<Int>]
        /// `text` as UTF-16, the unit every range counts in.
        let units: [UInt16]

        /// Every `rv-` id in use, by an anchor or a definition.
        public var ids: Set<String> {
            Set(anchors.map(\.id)).union(threads.map(\.id))
        }

        public func anchors(id: String) -> [Anchor] {
            anchors.filter { $0.id == id }
        }

        /// The first definition for `id`, the one Markdown readers show.
        public func thread(id: String) -> Thread? {
            threads.first { $0.id == id }
        }
    }

    // MARK: Parse

    public static func parse(_ text: String) -> Review {
        let units = Array(text.utf16)
        var parser = Parser(units: units)
        parser.run()
        return Review(text: text, anchors: parser.anchors, threads: parser.threads,
                      problems: parser.problems + crossCheck(parser.anchors, parser.threads),
                      literalBlocks: parser.literalBlocks, literalSpans: parser.literalSpans,
                      units: units)
    }

    /// Problems that need the whole document: orphans, dangling refs, mixed kinds.
    private static func crossCheck(_ anchors: [Anchor], _ threads: [Thread]) -> [Problem] {
        var problems: [Problem] = []
        let anchored = Set(anchors.map(\.id))
        let defined = Set(threads.map(\.id))
        for thread in threads where !anchored.contains(thread.id) {
            problems.append(.orphanThread(id: thread.id, range: thread.range))
        }
        for anchor in anchors where !defined.contains(anchor.id) {
            problems.append(.danglingAnchor(id: anchor.id, range: anchor.range))
        }
        var seen = Set<String>()
        for anchor in anchors where seen.insert(anchor.id).inserted {
            let kinds = Set(anchors.lazy.filter { $0.id == anchor.id }.map(\.kind.isSuggestion))
            if kinds.count > 1 { problems.append(.mixedKinds(id: anchor.id)) }
        }
        return problems
    }
}

// MARK: - Scanner

/// UTF-16 code units the scanner looks for. Every delimiter is ASCII, so a
/// match can never split a surrogate pair.
enum ReviewUnit {
    static let newline = UInt16(UInt8(ascii: "\n"))
    static let space = UInt16(UInt8(ascii: " "))
    static let tab = UInt16(UInt8(ascii: "\t"))
    static let backtick = UInt16(UInt8(ascii: "`"))
    static let tilde = UInt16(UInt8(ascii: "~"))
    static let dollar = UInt16(UInt8(ascii: "$"))
    static let greater = UInt16(UInt8(ascii: ">"))
    static let openBrace = UInt16(UInt8(ascii: "{"))
    static let closeBrace = UInt16(UInt8(ascii: "}"))
    static let openBracket = UInt16(UInt8(ascii: "["))
    static let closeBracket = UInt16(UInt8(ascii: "]"))
    static let caret = UInt16(UInt8(ascii: "^"))
    static let colon = UInt16(UInt8(ascii: ":"))
    static let at = UInt16(UInt8(ascii: "@"))
    static let hyphen = UInt16(UInt8(ascii: "-"))
    static let equals = UInt16(UInt8(ascii: "="))
    static let plus = UInt16(UInt8(ascii: "+"))
    static let star = UInt16(UInt8(ascii: "*"))
    static let dot = UInt16(UInt8(ascii: "."))
    static let paren = UInt16(UInt8(ascii: ")"))

    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    static func isIDChar(_ c: UInt16) -> Bool { isDigit(c) || (c >= 0x61 && c <= 0x7A) }
    static func isBlank(_ c: UInt16) -> Bool { c == space || c == tab }
}

private struct Parser {
    let u: [UInt16]
    var anchors: [ReviewMarkup.Anchor] = []
    var threads: [ReviewMarkup.Thread] = []
    var problems: [ReviewMarkup.Problem] = []
    var literalBlocks: [Range<Int>] = []
    var literalSpans: [Range<Int>] = []
    /// Lines as UTF-16 ranges, each excluding its "\n".
    private var lines: [Range<Int>] = []

    init(units: [UInt16]) {
        u = units
        var start = 0
        for (index, unit) in units.enumerated() where unit == ReviewUnit.newline {
            lines.append(start..<index)
            start = index + 1
        }
        if start < units.count { lines.append(start..<units.count) }
    }

    func string(_ range: Range<Int>) -> String {
        String(decoding: u[range], as: UTF16.self)
    }

    // MARK: Blocks

    /// Walk the lines, setting aside code fences, math blocks and thread
    /// definitions, and scan each remaining run of non-blank lines (a block,
    /// as far as CriticMarkup is concerned) for anchors.
    mutating func run() {
        var index = 0
        var block: Range<Int>?

        func flush(_ parser: inout Parser) {
            if let range = block { parser.scanInline(range) }
            block = nil
        }

        while index < lines.count {
            let line = lines[index]
            if let fence = fenceOpener(line) {
                flush(&self)
                index += 1
                while index < lines.count, !isFenceCloser(lines[index], fence) { index += 1 }
                literalBlocks.append(line.lowerBound..<lines[min(index, lines.count - 1)].upperBound)
                index += 1
            } else if let afterOpen = mathOpener(line) {
                flush(&self)
                if !contains(ReviewUnit.dollar, ReviewUnit.dollar, in: afterOpen..<line.upperBound) {
                    index += 1
                    while index < lines.count,
                          !contains(ReviewUnit.dollar, ReviewUnit.dollar, in: lines[index]) { index += 1 }
                }
                literalBlocks.append(line.lowerBound..<lines[min(index, lines.count - 1)].upperBound)
                index += 1
            } else if let (id, afterColon) = definitionLabel(line) {
                flush(&self)
                index = parseThread(id: id, firstLine: index, afterColon: afterColon)
            } else if line.allSatisfy({ ReviewUnit.isBlank(u[$0]) }) {
                flush(&self)
                index += 1
            } else {
                block = (block?.lowerBound ?? line.lowerBound)..<line.upperBound
                index += 1
            }
        }
        flush(&self)
    }

    /// Container prefixes (indentation, `>` quotes, one list marker) that may
    /// precede a fence or `$$` inside a quote or list item.
    private func skipContainerPrefix(_ line: Range<Int>) -> Int {
        var p = line.lowerBound
        while p < line.upperBound, ReviewUnit.isBlank(u[p]) || u[p] == ReviewUnit.greater { p += 1 }
        if p + 1 < line.upperBound, [ReviewUnit.hyphen, ReviewUnit.star, ReviewUnit.plus].contains(u[p]),
           ReviewUnit.isBlank(u[p + 1]) {
            p += 2
        } else {
            var q = p
            while q < line.upperBound, ReviewUnit.isDigit(u[q]) { q += 1 }
            if q > p, q + 1 < line.upperBound, u[q] == ReviewUnit.dot || u[q] == ReviewUnit.paren,
               ReviewUnit.isBlank(u[q + 1]) {
                p = q + 2
            }
        }
        while p < line.upperBound, ReviewUnit.isBlank(u[p]) { p += 1 }
        return p
    }

    private func run(of unit: UInt16, from start: Int, limit: Int) -> Int {
        var p = start
        while p < limit, u[p] == unit { p += 1 }
        return p - start
    }

    private func fenceOpener(_ line: Range<Int>) -> (unit: UInt16, count: Int)? {
        let p = skipContainerPrefix(line)
        guard p < line.upperBound, u[p] == ReviewUnit.backtick || u[p] == ReviewUnit.tilde else { return nil }
        let count = run(of: u[p], from: p, limit: line.upperBound)
        guard count >= 3 else { return nil }
        // A backtick fence's info string cannot contain a backtick.
        if u[p] == ReviewUnit.backtick,
           u[(p + count)..<line.upperBound].contains(ReviewUnit.backtick) { return nil }
        return (u[p], count)
    }

    private func isFenceCloser(_ line: Range<Int>, _ fence: (unit: UInt16, count: Int)) -> Bool {
        var p = line.lowerBound
        while p < line.upperBound, ReviewUnit.isBlank(u[p]) || u[p] == ReviewUnit.greater { p += 1 }
        let count = run(of: fence.unit, from: p, limit: line.upperBound)
        guard count >= fence.count else { return false }
        return u[(p + count)..<line.upperBound].allSatisfy(ReviewUnit.isBlank)
    }

    /// The offset after an opening `$$`, if the line starts a math block.
    private func mathOpener(_ line: Range<Int>) -> Int? {
        var p = line.lowerBound
        while p < line.upperBound, ReviewUnit.isBlank(u[p]) || u[p] == ReviewUnit.greater { p += 1 }
        guard p + 1 < line.upperBound, u[p] == ReviewUnit.dollar, u[p + 1] == ReviewUnit.dollar else { return nil }
        return p + 2
    }

    private func contains(_ a: UInt16, _ b: UInt16, in range: Range<Int>) -> Bool {
        guard range.count >= 2 else { return false }
        return (range.lowerBound..<(range.upperBound - 1)).contains { u[$0] == a && u[$0 + 1] == b }
    }

    // MARK: Threads

    /// `[^rv-xxxx]:` at the start of a line (up to three spaces of indent).
    private func definitionLabel(_ line: Range<Int>) -> (String, Int)? {
        var p = line.lowerBound
        while p < line.upperBound, p - line.lowerBound < 3, u[p] == ReviewUnit.space { p += 1 }
        guard let (id, end) = ref(at: p, limit: line.upperBound),
              end < line.upperBound, u[end] == ReviewUnit.colon else { return nil }
        return (id, end + 1)
    }

    /// Consume a definition block: the label line, then indented lines and
    /// unindented entry lines up to the first blank line. Returns the index of
    /// the first line after the block.
    private mutating func parseThread(id: String, firstLine: Int, afterColon: Int) -> Int {
        var entries: [ReviewMarkup.Entry] = []
        var malformed: [Range<Int>] = []

        func add(_ content: Range<Int>, entryRange: Range<Int>, _ parser: Parser) {
            if let entry = parser.entry(content, range: entryRange) {
                entries.append(entry)
            } else {
                entries.append(ReviewMarkup.Entry(
                    author: "", date: "", kind: .comment,
                    body: parser.string(parser.trimmed(content)), range: entryRange))
                malformed.append(entryRange)
            }
        }

        let first = lines[firstLine]
        var p = afterColon
        while p < first.upperBound, ReviewUnit.isBlank(u[p]) { p += 1 }
        add(p..<first.upperBound, entryRange: p..<first.upperBound, self)

        var index = firstLine + 1
        while index < lines.count {
            let line = lines[index]
            var content = line.lowerBound
            while content < line.upperBound, ReviewUnit.isBlank(u[content]) { content += 1 }
            guard content < line.upperBound else { break }             // blank line ends it
            let indented = u[line.lowerBound] == ReviewUnit.tab
                || content - line.lowerBound >= 4
            if entry(content..<line.upperBound, range: line) != nil {
                add(content..<line.upperBound, entryRange: line, self)
            } else if indented, !entries.isEmpty {
                // A continuation of the previous entry's body.
                let last = entries.count - 1
                let piece = string(trimmed(content..<line.upperBound))
                entries[last].body += entries[last].body.isEmpty ? piece : "\n" + piece
                entries[last].range = entries[last].range.lowerBound..<line.upperBound
            } else {
                break
            }
            index += 1
        }

        let lastLine = lines[index - 1]
        let end = lastLine.upperBound < u.count ? lastLine.upperBound + 1 : lastLine.upperBound
        let range = first.lowerBound..<end
        if threads.contains(where: { $0.id == id }) {
            problems.append(.duplicateThread(id: id, range: range))
        }
        problems += malformed.map { .malformedEntry(id: id, range: $0) }
        threads.append(ReviewMarkup.Thread(id: id, range: range, entries: entries))
        return index
    }

    private func trimmed(_ range: Range<Int>) -> Range<Int> {
        var lower = range.lowerBound, upper = range.upperBound
        while lower < upper, ReviewUnit.isBlank(u[lower]) { lower += 1 }
        while upper > lower, ReviewUnit.isBlank(u[upper - 1]) { upper -= 1 }
        return lower..<upper
    }

    /// `@author YYYY-MM-DD[ suggestion]:[ body]`, or nil.
    private func entry(_ content: Range<Int>, range: Range<Int>) -> ReviewMarkup.Entry? {
        var p = content.lowerBound
        let end = content.upperBound
        guard p < end, u[p] == ReviewUnit.at else { return nil }
        p += 1
        let authorStart = p
        while p < end, !ReviewUnit.isBlank(u[p]) { p += 1 }
        guard p > authorStart, p < end, u[p] == ReviewUnit.space else { return nil }
        let author = authorStart..<p
        p += 1

        // YYYY-MM-DD
        let dateStart = p
        for expectDigit in [true, true, true, true, false, true, true, false, true, true] {
            guard p < end else { return nil }
            if expectDigit ? !ReviewUnit.isDigit(u[p]) : u[p] != ReviewUnit.hyphen { return nil }
            p += 1
        }
        let date = dateStart..<p

        var kind = ReviewMarkup.EntryKind.comment
        let marker = Array(" suggestion".utf16)
        if end - p >= marker.count, Array(u[p..<(p + marker.count)]) == marker {
            kind = .suggestion
            p += marker.count
        }
        guard p < end, u[p] == ReviewUnit.colon else { return nil }
        p += 1
        return ReviewMarkup.Entry(author: string(author), date: string(date), kind: kind,
                                  body: string(trimmed(p..<end)), range: range)
    }

    // MARK: Inline

    /// `[^rv-xxxx]` starting at `p`: the id and the offset after `]`.
    private func ref(at p: Int, limit: Int) -> (String, Int)? {
        let prefix: [UInt16] = Array("[^rv-".utf16)
        guard p + prefix.count < limit, Array(u[p..<(p + prefix.count)]) == prefix else { return nil }
        var q = p + prefix.count
        while q < limit, ReviewUnit.isIDChar(u[q]) { q += 1 }
        guard q > p + prefix.count, q < limit, u[q] == ReviewUnit.closeBracket else { return nil }
        return (string((p + 2)..<q), q + 1)
    }

    private func kind(opener a: UInt16, _ b: UInt16) -> ReviewMarkup.AnchorKind? {
        guard a == b else { return nil }
        switch a {
        case ReviewUnit.equals: return .highlight
        case ReviewUnit.plus: return .insertion
        case ReviewUnit.hyphen: return .deletion
        case ReviewUnit.tilde: return .substitution
        default: return nil
        }
    }

    private func delimiterUnit(_ kind: ReviewMarkup.AnchorKind) -> UInt16 {
        switch kind {
        case .highlight: return ReviewUnit.equals
        case .insertion: return ReviewUnit.plus
        case .deletion: return ReviewUnit.hyphen
        case .substitution, .point: return ReviewUnit.tilde
        }
    }

    private func isCloser(at p: Int, limit: Int) -> Bool {
        p + 2 < limit && u[p + 2] == ReviewUnit.closeBrace && kind(opener: u[p], u[p + 1]) != nil
    }

    /// If a code span opens at `p`, the offset after it closes.
    private func codeSpanEnd(at p: Int, limit: Int) -> Int? {
        guard u[p] == ReviewUnit.backtick else { return nil }
        let count = run(of: ReviewUnit.backtick, from: p, limit: limit)
        var q = p + count
        while q < limit {
            if u[q] == ReviewUnit.backtick {
                let closing = run(of: ReviewUnit.backtick, from: q, limit: limit)
                if closing == count { return q + closing }
                q += closing
            } else {
                q += 1
            }
        }
        return nil
    }

    /// The offset of the first `xx}` closer for `kind` at or after `start`,
    /// stepping over code spans.
    private func closer(for kind: ReviewMarkup.AnchorKind, from start: Int, limit: Int) -> Int? {
        let unit = delimiterUnit(kind)
        var q = start
        while q < limit {
            if let after = codeSpanEnd(at: q, limit: limit) { q = after; continue }
            if q + 2 < limit, u[q] == unit, u[q + 1] == unit, u[q + 2] == ReviewUnit.closeBrace { return q }
            q += 1
        }
        return nil
    }

    private mutating func scanInline(_ block: Range<Int>) {
        let limit = block.upperBound
        var p = block.lowerBound
        while p < limit {
            if u[p] == ReviewUnit.backtick {
                if let end = codeSpanEnd(at: p, limit: limit) {
                    literalSpans.append(p..<end)
                    p = end
                } else {
                    p += run(of: ReviewUnit.backtick, from: p, limit: limit)
                }
                continue
            }
            if u[p] == ReviewUnit.openBrace, p + 2 < limit, let kind = kind(opener: u[p + 1], u[p + 2]) {
                p = scanAnchor(kind, at: p, limit: limit)
                continue
            }
            if let (id, end) = ref(at: p, limit: limit) {
                anchors.append(ReviewMarkup.Anchor(id: id, kind: .point, range: p..<end,
                                                   inner: p..<p, ref: p..<end))
                p = end
                continue
            }
            if isCloser(at: p, limit: limit) {
                problems.append(.unbalanced(range: p..<(p + 3)))
                p += 3
                continue
            }
            p += 1
        }
    }

    /// Scan the anchor opening at `p`; returns where scanning resumes.
    private mutating func scanAnchor(_ kind: ReviewMarkup.AnchorKind, at p: Int, limit: Int) -> Int {
        let innerStart = p + 3
        guard let close = closer(for: kind, from: innerStart, limit: limit) else {
            problems.append(.unbalanced(range: p..<innerStart))
            return innerStart
        }
        var old: Range<Int>?, new: Range<Int>?
        if kind == .substitution {
            guard let arrow = (innerStart..<close).first(where: {
                $0 + 1 < close && u[$0] == ReviewUnit.tilde && u[$0 + 1] == ReviewUnit.greater
            }) else {
                problems.append(.unbalanced(range: p..<innerStart))
                return innerStart
            }
            old = innerStart..<arrow
            new = (arrow + 2)..<close
        }
        let afterCloser = close + 3
        // Bare CriticMarkup with no `[^rv-…]` is plain text to review.
        guard let (id, end) = ref(at: afterCloser, limit: limit) else { return afterCloser }
        anchors.append(ReviewMarkup.Anchor(
            id: id, kind: kind, range: p..<end, inner: innerStart..<close,
            old: old, new: new, ref: afterCloser..<end))
        return end
    }
}
