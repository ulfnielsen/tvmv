import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// The layout-manager delegate that hides markup and reflows soft breaks.
/// The text view holds it strongly: `NSLayoutManager.delegate` is weak.
public final class MarkupLayoutDelegate: NSObject, @preconcurrency NSLayoutManagerDelegate {
    /// Soft line breaks lay out as spaces: the paragraph reflows.
    public func layoutManager(_ lm: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                              forControlCharacterAt index: Int) -> NSLayoutManager.ControlCharacterAction {
        lm.textStorage?.attribute(.tvmvSoftBreak, at: index, effectiveRange: nil) != nil ? .whitespace : action
    }

    /// A whitespace-action control glyph is zero-wide unless sized here:
    /// a soft break takes the width of a space, or words run together.
    public func layoutManager(_ lm: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                              for textContainer: NSTextContainer, proposedLineFragment: CGRect,
                              glyphPosition: CGPoint, characterIndex: Int) -> CGRect {
        let font = lm.textStorage?.attribute(.font, at: characterIndex, effectiveRange: nil) as? PlatformFont
            ?? .systemFont(ofSize: PlatformFont.systemFontSize)
        let width = (" " as NSString).size(withAttributes: [.font: font]).width
        return CGRect(x: glyphPosition.x, y: 0, width: width, height: proposedLineFragment.height)
    }

    public func layoutManager(_ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                              properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                              characterIndexes: UnsafePointer<Int>, font: PlatformFont,
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
