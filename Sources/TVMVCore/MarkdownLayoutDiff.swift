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
        widen(old.listItems, listItems, { $0.marker }) { o, n, d in
            o.marker.shifted(by: d) == n.marker && o.bullet.shifted(by: d) == n.bullet && o.level == n.level
                && o.ordered == n.ordered && o.task == n.task && o.checkbox?.shifted(by: d) == n.checkbox
        }
        widen(old.quoteLines, quoteLines, { $0.prefix }) { o, n, d in
            o.prefix.shifted(by: d) == n.prefix && o.level == n.level
        }
        widen(old.tables, tables, { $0.range }) { o, n, d in
            o.range.shifted(by: d) == n.range && o.alignments == n.alignments
                && o.rows.map { $0.map { $0.shifted(by: d) } } == n.rows
        }
        widen(old.blockImages, blockImages, { $0.range }) { o, n, d in
            o.range.shifted(by: d) == n.range && o.url == n.url && o.alt == n.alt
        }
        widen(old.softBreaks.map { NSRange(location: $0, length: 1) }, softBreaks.map { NSRange(location: $0, length: 1) },
              { $0 }) { o, n, d in o.shifted(by: d) == n }
        widen(old.codeBlocks, codeBlocks, { $0.range }) { o, n, d in
            o.range.shifted(by: d) == n.range && o.body.shifted(by: d) == n.body
        }
        start = max(0, min(start, length))
        end = min(length, max(end, start))
        return NSRange(location: start, length: end - start)
    }
}

