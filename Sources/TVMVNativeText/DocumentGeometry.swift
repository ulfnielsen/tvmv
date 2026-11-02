import CoreGraphics
import Foundation
import TVMVCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Where things sit in a laid-out document, in view coordinates (the text
/// container at `origin`): list items, task boxes, the line at a scroll offset.
public enum DocumentGeometry {
    /// Where a list item's text starts on screen (its line fragment and the
    /// x of the text), or nil if not laid out.
    public static func listItem(_ item: MarkdownLayout.ListItem,
                                _ input: DecorationInput) -> (fragment: CGRect, baseline: CGFloat, textX: CGFloat)? {
        let lm = input.layoutManager, storage = input.storage
        guard NSMaxRange(item.marker) <= storage.length else { return nil }
        // Anchor on the first visible character of the line: hidden glyphs at
        // a line's start (an italic first word's "*") sit on the line before.
        let text = storage.string as NSString
        let line = text.lineRange(for: NSRange(location: item.marker.location, length: 0))
        var content = min(NSMaxRange(item.marker), max(0, storage.length - 1))
        while content < NSMaxRange(line) - 1, input.isHidden(content) { content += 1 }
        let glyph = lm.glyphIndexForCharacter(at: content)
        let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let style = storage.attribute(.paragraphStyle, at: content, effectiveRange: nil) as? NSParagraphStyle
        let textX = input.origin.x + input.textContainer.lineFragmentPadding + (style?.firstLineHeadIndent ?? 0)
        let baseline = fragment.minY + input.origin.y + lm.location(forGlyphAt: glyph).y
        return (fragment, baseline, textX)
    }

    /// The clickable checkbox of a task item.
    public static func taskBox(_ item: MarkdownLayout.ListItem, _ input: DecorationInput) -> CGRect? {
        guard item.task != nil, let g = listItem(item, input) else { return nil }
        let em = input.theme.body.pointSize
        let side = em * 0.8
        return CGRect(x: g.textX - side - em * 0.45, y: g.baseline - side * 0.95, width: side, height: side)
    }

    /// UTF-16 offset of the first character at `y`.
    public static func topVisibleOffset(y: CGFloat, layoutManager: NSLayoutManager, textContainer: NSTextContainer,
                                        origin: CGPoint) -> Int {
        // One point below the edge: exactly at it, the line above (whose
        // fragment includes its paragraph spacing) would claim the point.
        let point = CGPoint(x: 0, y: max(0, y - origin.y + 1))
        return layoutManager.characterIndexForGlyph(at: layoutManager.glyphIndex(for: point, in: textContainer))
    }

    /// The top of the line holding `offset`, in text container coordinates,
    /// laying out the text up to it first. The text must not be empty.
    public static func lineTop(offset: Int, layoutManager: NSLayoutManager, textContainer: NSTextContainer) -> CGFloat {
        let length = layoutManager.textStorage?.length ?? 0
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: min(max(0, offset), length - 1), length: 1),
                                              actualCharacterRange: nil)
        layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: NSMaxRange(glyphs)))
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).minY
    }
}
