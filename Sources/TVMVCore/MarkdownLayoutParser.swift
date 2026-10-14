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

