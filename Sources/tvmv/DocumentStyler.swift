import AppKit
import TVMVCore

/// Applies a `MarkdownLayout` to a text storage, limited to one range.
enum DocumentStyler {
    /// Where a list item's text starts at nesting `level`; its bullet sits in the em before.
    static func listIndent(level: Int, em: CGFloat) -> CGFloat { CGFloat(level + 1) * 1.6 * em }
    /// Where quoted text starts at quote depth `level`; one rule per level sits to its left.
    static func quoteIndent(level: Int, em: CGFloat) -> CGFloat { CGFloat(level) * 1.2 * em }

    /// - Parameter isRevealed: whether a reveal unit's markup is currently shown.
    /// - Parameter imageHeight: the height a block image is drawn at, once
    ///   loaded (nil while loading or after a failure: a normal text line).
    static func apply(_ layout: MarkdownLayout, to storage: NSTextStorage, in range: NSRange,
                      theme: NativeTheme, isRevealed: (NSRange) -> Bool,
                      imageHeight: (MarkdownLayout.BlockImage) -> CGFloat? = { _ in nil },
                      tableHeight: (Int) -> CGFloat? = { _ in nil }) {
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
                storage.addAttributes([.font: theme.headingFont(level),
                                       .paragraphStyle: theme.headingParagraph(level)], range: r)
            case .emphasis:
                addTrait(.italicFontMask, r)
            case .strong:
                addTrait(.boldFontMask, r)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .code:
                // The pill behind it is drawn by DocumentTextView: a background
                // attribute would fill the whole (1.7×) line height.
                storage.addAttribute(.font, value: theme.mono, range: r)
            case .codeBlock:
                storage.addAttribute(.font, value: theme.mono, range: r)
            case .link(let url), .autolink(let url):
                storage.addAttributes([.foregroundColor: theme.accent, .tvmvLink: url,
                                       .underlineStyle: NSUnderlineStyle.single.rawValue], range: r)
            case .html, .image:
                storage.addAttributes([.font: theme.mono, .foregroundColor: theme.muted], range: r)
            }
        }
        // Blank lines (outside code) are the gap between blocks.
        let text = storage.string as NSString
        var lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
        while lineStart < NSMaxRange(range), lineStart < text.length {
            let line = text.lineRange(for: NSRange(location: lineStart, length: 0))
            if line.length == 1, text.character(at: line.location) == 10,
               !layout.codeBlocks.contains(where: { NSLocationInRange(line.location, $0.range) }),
               let r = clip(line) {
                storage.addAttribute(.paragraphStyle, value: theme.blankLineParagraph, range: r)
            }
            lineStart = NSMaxRange(line)
        }
        for offset in layout.softBreaks {
            if let r = clip(NSRange(location: offset, length: 1)) { storage.addAttribute(.tvmvSoftBreak, value: true, range: r) }
        }
        for block in layout.codeBlocks where block.body.length > 0 {
            guard NSIntersectionRange(block.body, range).length > 0 else { continue }
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
        // Block images: the source hides and its line takes the picture's
        // height plus a half-em margin above and below (drawn by the view).
        for image in layout.blockImages where !isRevealed(image.range) {
            guard let r = clip(image.range) else { continue }
            storage.addAttribute(.tvmvHidden, value: true, range: r)
            if let height = imageHeight(image) {
                let p = NSMutableParagraphStyle()
                p.minimumLineHeight = height + theme.body.pointSize
                p.maximumLineHeight = height + theme.body.pointSize
                storage.addAttribute(.paragraphStyle, value: p, range: r)
            }
        }
        // Tables: the source hides (its final newline too, so the caret
        // passes it as one collapsed block); the first line reserves the
        // grid's height plus a half-em margin each side, the rest collapse.
        let tableText = storage.string as NSString
        for (index, table) in layout.tables.enumerated() where !isRevealed(table.range) {
            var hidden = table.range
            if NSMaxRange(hidden) < tableText.length, tableText.character(at: NSMaxRange(hidden)) == 10 { hidden.length += 1 }
            guard let r = clip(hidden) else { continue }
            storage.addAttribute(.tvmvHidden, value: true, range: r)
            let firstLine = tableText.lineRange(for: NSRange(location: table.range.location, length: 0))
            if let height = tableHeight(index), let first = clip(firstLine) {
                let p = NSMutableParagraphStyle()
                p.minimumLineHeight = height + theme.body.pointSize
                p.maximumLineHeight = height + theme.body.pointSize
                storage.addAttribute(.paragraphStyle, value: p, range: first)
            }
            let rest = NSRange(location: NSMaxRange(firstLine), length: max(0, NSMaxRange(hidden) - NSMaxRange(firstLine)))
            if let r = clip(rest) {
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.1),
                                       .paragraphStyle: NativeTheme.collapsedParagraph], range: r)
            }
        }
        // Quotes and lists: the prefix and marker hide; the line indents (the
        // view draws the rule, bullet, number or checkbox in the space). When
        // the markup shows, it takes that space instead, so the text stays put.
        let em = theme.body.pointSize
        func width(_ r: NSRange) -> CGFloat {
            (tableText.substring(with: r) as NSString).size(withAttributes: [.font: theme.body]).width
        }
        var indents: [Int: (amount: CGFloat, shown: CGFloat)] = [:]   // by line start
        for quote in layout.quoteLines {
            let line = tableText.lineRange(for: NSRange(location: quote.prefix.location, length: 0))
            if let r = clip(line) { storage.addAttribute(.foregroundColor, value: theme.inkSoft, range: r) }
            var entry = indents[line.location] ?? (0, 0)
            entry.amount += quoteIndent(level: quote.level, em: em)
            if isRevealed(quote.prefix) { entry.shown += width(quote.prefix) }
            else if let r = clip(quote.prefix) { storage.addAttribute(.tvmvHidden, value: true, range: r) }
            indents[line.location] = entry
        }
        for item in layout.listItems {
            let line = tableText.lineRange(for: NSRange(location: item.marker.location, length: 0))
            var entry = indents[line.location] ?? (0, 0)
            // The gutter fits the marker as typed ("- [ ] ", "10. "), so it can
            // take the bullet's place without moving the text.
            let gutterStart = listIndent(level: item.level, em: em) - 1.6 * em
            let markerWidth = width(item.marker)
            // Checked and open boxes share one gutter, so a task list lines up.
            let gutterWidth = item.task == nil ? markerWidth
                : ((tableText.substring(with: item.marker).replacingOccurrences(of: "[ ]", with: "[x]")) as NSString)
                    .size(withAttributes: [.font: theme.body]).width
            entry.amount += max(listIndent(level: item.level, em: em), gutterStart + gutterWidth)
            if isRevealed(item.marker) { entry.shown += markerWidth }
            else if let r = clip(item.marker) { storage.addAttribute(.tvmvHidden, value: true, range: r) }
            indents[line.location] = entry
        }
        for (start, entry) in indents {
            guard let r = clip(tableText.lineRange(for: NSRange(location: start, length: 0))) else { continue }
            let current = (storage.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)
                ?? theme.paragraphStyle
            let p = current.mutableCopy() as! NSMutableParagraphStyle
            p.firstLineHeadIndent = max(0, entry.amount - entry.shown)
            p.headIndent = entry.amount
            storage.addAttribute(.paragraphStyle, value: p, range: r)
        }
        for exempt in layout.spellExempt {
            if let r = clip(exempt) { storage.addAttribute(.tvmvNoSpell, value: true, range: r) }
        }
        storage.endEditing()
    }
}
