import Foundation

/// Review operations as plain text edits.
///
/// Every operation returns `TextPatcher.Patch`es against the parsed text:
/// UTF-16, ascending and non-overlapping, so the editor applies them as one
/// undoable edit through its single edit path. An operation that cannot be
/// expressed as well-formed markup (a range across blocks, inside code, or
/// overlapping another anchor) returns no patches rather than a broken file.
/// Each one also re-parses its own result and returns nothing if the outcome
/// is not exactly what it meant to write.
extension ReviewMarkup {

    private static let idAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// A fresh `rv-` id: four random characters, so two branches never mint
    /// the same one.
    public static func newID(existing: Set<String>) -> String {
        var generator = SystemRandomNumberGenerator()
        return newID(existing: existing, using: &generator)
    }

    public static func newID<G: RandomNumberGenerator>(
        existing: Set<String>, using generator: inout G
    ) -> String {
        while true {
            let suffix = (0..<4).map { _ in idAlphabet.randomElement(using: &generator)! }
            let id = "rv-" + String(suffix)
            if !existing.contains(id) { return id }
        }
    }
}

extension ReviewMarkup.Review {

    public typealias Patch = TextPatcher.Patch

    // MARK: Create

    /// Comment on `range`: a highlight, or a point comment when the range is
    /// empty. A range inside a code fence or math block becomes a point
    /// comment on its own line directly after the block.
    public func addComment(
        range: Range<Int>, body: String, author: String,
        date: Date, timeZone: TimeZone = .current, id: String? = nil
    ) -> [Patch] {
        let id = id ?? ReviewMarkup.newID(existing: ids)
        guard isFresh(id), range.lowerBound >= 0, range.upperBound <= units.count else { return [] }
        let definition = definitionPatch(id: id, kind: .comment, body: body, author: author,
                                         date: date, timeZone: timeZone)

        if let block = literalBlocks.first(where: {
            $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound
        }) {
            let end = block.upperBound
            let point = end < units.count
                ? Patch(from: end + 1, to: end + 1, insert: "[^\(id)]\n")
                : Patch(from: end, to: end, insert: "\n[^\(id)]")
            return verified([point, definition], id: id, kind: .point, inner: [""])
        }

        guard isPlaceable(range) else { return [] }
        if range.isEmpty {
            let point = Patch(from: range.lowerBound, to: range.lowerBound, insert: "[^\(id)]")
            return verified([point, definition], id: id, kind: .point, inner: [""])
        }
        return verified([
            Patch(from: range.lowerBound, to: range.lowerBound, insert: "{=="),
            Patch(from: range.upperBound, to: range.upperBound, insert: "==}[^\(id)]"),
            definition,
        ], id: id, kind: .highlight, inner: [slice(range)])
    }

    /// Suggest replacing `range` with `replacement`: a substitution, an
    /// insertion when the range is empty, or a deletion when the replacement is.
    public func addSuggestion(
        range: Range<Int>, replacement: String, body: String, author: String,
        date: Date, timeZone: TimeZone = .current, id: String? = nil
    ) -> [Patch] {
        let id = id ?? ReviewMarkup.newID(existing: ids)
        guard isFresh(id), range.lowerBound >= 0, range.upperBound <= units.count,
              !(range.isEmpty && replacement.isEmpty),
              !Self.hasBlankLine(Array(replacement.utf16)),
              isPlaceable(range),
              !literalBlocks.contains(where: { Self.touches(range, $0) })
        else { return [] }

        let definition = definitionPatch(id: id, kind: .suggestion, body: body, author: author,
                                         date: date, timeZone: timeZone)
        let ref = "[^\(id)]"
        let start = range.lowerBound, end = range.upperBound
        if range.isEmpty {
            return verified([Patch(from: start, to: start, insert: "{++\(replacement)++}\(ref)"),
                             definition],
                            id: id, kind: .insertion, inner: [replacement])
        }
        if replacement.isEmpty {
            return verified([Patch(from: start, to: start, insert: "{--"),
                             Patch(from: end, to: end, insert: "--}\(ref)"),
                             definition],
                            id: id, kind: .deletion, inner: [slice(range)])
        }
        return verified([Patch(from: start, to: start, insert: "{~~"),
                         Patch(from: end, to: end, insert: "~>\(replacement)~~}\(ref)"),
                         definition],
                        id: id, kind: .substitution, inner: [slice(range), replacement])
    }

    /// Append an entry to the thread for `id`, after its last line.
    public func reply(
        id: String, body: String, author: String,
        date: Date, timeZone: TimeZone = .current
    ) -> [Patch] {
        guard let thread = thread(id: id) else { return [] }
        let lines = Self.entryLines(kind: .comment, body: body, author: author,
                                    date: date, timeZone: timeZone)
        let entry = lines.map { "    " + $0 }.joined(separator: "\n")
        let end = thread.range.upperBound
        let patch = end > 0 && units[end - 1] == ReviewUnit.newline
            ? Patch(from: end, to: end, insert: entry + "\n")
            : Patch(from: end, to: end, insert: "\n" + entry)

        guard let result = TextPatcher.apply([patch], to: text) else { return [] }
        let after = ReviewMarkup.parse(result)
        guard after.problems.count == problems.count,
              after.thread(id: id)?.entries.count == thread.entries.count + 1
        else { return [] }
        return [patch]
    }

    // MARK: Settle

    /// Resolve a comment thread: highlights keep their text, point refs and
    /// the definition go. Suggestions are accepted or rejected instead, so an
    /// id with any suggestion anchor returns no patches.
    public func resolve(id: String) -> [Patch] {
        guard !anchors(id: id).contains(where: \.kind.isSuggestion) else { return [] }
        return settle([id], accepting: true)
    }

    /// Accept every anchor under `id` (a comment id is resolved).
    public func accept(id: String) -> [Patch] {
        settle([id], accepting: true)
    }

    /// Reject every anchor under `id` (a comment id is resolved).
    public func reject(id: String) -> [Patch] {
        settle([id], accepting: false)
    }

    /// Accept every suggestion thread. Comment threads stay open.
    public func acceptAll() -> [Patch] {
        settle(suggestionIDs, accepting: true)
    }

    /// Reject every suggestion thread. Comment threads stay open.
    public func rejectAll() -> [Patch] {
        settle(suggestionIDs, accepting: false)
    }

    private var suggestionIDs: Set<String> {
        Set(anchors.filter(\.kind.isSuggestion).map(\.id))
    }

    private func settle(_ ids: Set<String>, accepting: Bool) -> [Patch] {
        var removals: [Range<Int>] = []
        for anchor in anchors where ids.contains(anchor.id) {
            removals += settleRemovals(anchor, accepting: accepting)
        }
        removals += definitionRemovals(threads.filter { ids.contains($0.id) }.map(\.range))
        guard !removals.isEmpty else { return [] }

        removals.sort { $0.lowerBound < $1.lowerBound }
        var previous = 0
        for range in removals {
            guard range.lowerBound >= previous else { return [] }   // never overlap
            previous = range.upperBound
        }
        let patches = removals.filter { !$0.isEmpty }
            .map { Patch(from: $0.lowerBound, to: $0.upperBound, insert: "") }

        guard let result = TextPatcher.apply(patches, to: text) else { return [] }
        let after = ReviewMarkup.parse(result)
        guard after.ids.isDisjoint(with: ids) else { return [] }
        return patches
    }

    /// The text to cut for one anchor, per the settle table in the spec.
    private func settleRemovals(_ anchor: ReviewMarkup.Anchor, accepting: Bool) -> [Range<Int>] {
        func keep(_ inner: Range<Int>) -> [Range<Int>] {
            [anchor.range.lowerBound..<inner.lowerBound, inner.upperBound..<anchor.range.upperBound]
        }
        switch anchor.kind {
        case .highlight:
            return keep(anchor.inner)
        case .point:
            return [pointRemoval(anchor.range)]
        case .insertion:
            return accepting ? keep(anchor.inner) : [anchor.range]
        case .deletion:
            return accepting ? [anchor.range] : keep(anchor.inner)
        case .substitution:
            guard let old = anchor.old, let new = anchor.new else { return [] }
            return keep(accepting ? new : old)
        }
    }

    /// A point ref alone on its line (a comment on a code block) takes its
    /// line with it; elsewhere only the ref goes.
    private func pointRemoval(_ ref: Range<Int>) -> Range<Int> {
        let atLineStart = ref.lowerBound == 0 || units[ref.lowerBound - 1] == ReviewUnit.newline
        let atLineEnd = ref.upperBound == units.count || units[ref.upperBound] == ReviewUnit.newline
        guard atLineStart, atLineEnd else { return ref }
        if ref.upperBound < units.count { return ref.lowerBound..<(ref.upperBound + 1) }
        if ref.lowerBound > 0 { return (ref.lowerBound - 1)..<ref.upperBound }
        return ref
    }

    /// Definition blocks to cut. Adjacent blocks merge into one run, and a run
    /// with a blank line before it and nothing but a blank line or the end of
    /// the file after it takes that blank line too, undoing the separator
    /// `addComment` put before the first definition.
    private func definitionRemovals(_ blocks: [Range<Int>]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        for block in blocks.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = runs.last, last.upperBound == block.lowerBound {
                runs[runs.count - 1] = last.lowerBound..<block.upperBound
            } else {
                runs.append(block)
            }
        }
        return runs.map { run in
            let start = run.lowerBound
            let blankBefore = start >= 1 && units[start - 1] == ReviewUnit.newline
                && (start == 1 || units[start - 2] == ReviewUnit.newline)
            let blankAfter = run.upperBound == units.count || units[run.upperBound] == ReviewUnit.newline
            return blankBefore && blankAfter ? (start - 1)..<run.upperBound : run
        }
    }

    // MARK: Helpers


    private func slice(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    private func isFresh(_ id: String) -> Bool {
        id.range(of: "^rv-[a-z0-9]+$", options: .regularExpression) != nil && !ids.contains(id)
    }

    /// Whether `a` and `b` share any position, treating an empty range as a
    /// caret that must not sit strictly inside `b`.
    private static func touches(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        a.isEmpty
            ? b.lowerBound < a.lowerBound && a.lowerBound < b.upperBound
            : a.lowerBound < b.upperBound && a.upperBound > b.lowerBound
    }

    private static func hasBlankLine(_ units: [UInt16]) -> Bool {
        var sawNewline = false
        for unit in units {
            if unit == ReviewUnit.newline {
                if sawNewline { return true }
                sawNewline = true
            } else if unit != ReviewUnit.space && unit != ReviewUnit.tab {
                sawNewline = false
            }
        }
        return false
    }

    /// Whether new delimiters can wrap `range`: one block, outside code spans,
    /// thread definitions and every existing anchor.
    private func isPlaceable(_ range: Range<Int>) -> Bool {
        if Self.hasBlankLine(Array(units[range])) { return false }
        if anchors.contains(where: { Self.touches(range, $0.range) }) { return false }
        if threads.contains(where: {
            Self.touches(range, $0.range) || range.lowerBound == $0.range.lowerBound
        }) { return false }
        for span in literalSpans {
            let inside = { (p: Int) in span.lowerBound < p && p < span.upperBound }
            if inside(range.lowerBound) || inside(range.upperBound) { return false }
        }
        return true
    }

    /// Apply `patches` and confirm the result holds exactly one new anchor of
    /// `kind` under `id`, with the intended text, a one-entry thread, and no
    /// new problems. Anything else returns no patches.
    private func verified(_ patches: [Patch], id: String, kind: ReviewMarkup.AnchorKind,
                          inner expected: [String]) -> [Patch] {
        guard let result = TextPatcher.apply(patches, to: text) else { return [] }
        let after = ReviewMarkup.parse(result)
        let resultUnits = Array(result.utf16)
        func excerpt(_ range: Range<Int>?) -> String? {
            range.map { String(decoding: resultUnits[$0], as: UTF16.self) }
        }
        let anchors = after.anchors(id: id)
        guard anchors.count == 1, let anchor = anchors.first, anchor.kind == kind,
              after.thread(id: id)?.entries.count == 1,
              after.problems.count == problems.count
        else { return [] }
        let actual: [String?] = kind == .substitution
            ? [excerpt(anchor.old), excerpt(anchor.new)]
            : [excerpt(anchor.inner)]
        return actual == expected ? patches : []
    }

    /// `@author YYYY-MM-DD[ suggestion]: first line`, then any further body
    /// lines. Blank lines would end the footnote, so they are dropped.
    private static func entryLines(
        kind: ReviewMarkup.EntryKind, body: String, author: String,
        date: Date, timeZone: TimeZone
    ) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let stamp = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)

        // The entry form allows no space in the author.
        let name = author.drop { $0 == "@" || $0.isWhitespace }
            .prefix { !$0.isWhitespace }
        let header = "@\(name.isEmpty ? "anonymous" : String(name)) \(stamp)"
            + (kind == .suggestion ? " suggestion:" : ":")

        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return [header] }
        return ["\(header) \(first)"] + lines.dropFirst()
    }

    private func definitionPatch(
        id: String, kind: ReviewMarkup.EntryKind, body: String, author: String,
        date: Date, timeZone: TimeZone
    ) -> Patch {
        let lines = Self.entryLines(kind: kind, body: body, author: author,
                                    date: date, timeZone: timeZone)
        let definition = "[^\(id)]: " + lines.joined(separator: "\n    ") + "\n"

        // Directly after an existing thread at the end of the file; otherwise
        // after a blank line, which keeps the definitions out of the last
        // paragraph.
        let count = units.count
        var contentEnd = count
        while contentEnd > 0, [ReviewUnit.newline, ReviewUnit.space, ReviewUnit.tab].contains(units[contentEnd - 1]) {
            contentEnd -= 1
        }
        let endsWithNewline = count > 0 && units[count - 1] == ReviewUnit.newline
        let prefix: String
        if contentEnd == 0 || threads.contains(where: { $0.range.contains(contentEnd - 1) }) {
            prefix = count == 0 || endsWithNewline ? "" : "\n"
        } else if endsWithNewline {
            prefix = count >= 2 && units[count - 2] == ReviewUnit.newline ? "" : "\n"
        } else {
            prefix = "\n\n"
        }
        return Patch(from: count, to: count, insert: prefix + definition)
    }
}
