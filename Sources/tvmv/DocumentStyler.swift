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
        for exempt in layout.spellExempt {
            if let r = clip(exempt) { storage.addAttribute(.tvmvNoSpell, value: true, range: r) }
        }
        storage.endEditing()
    }
}
