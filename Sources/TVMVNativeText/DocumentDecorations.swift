import CoreGraphics
import Foundation
import TVMVCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// What the decorations of a laid-out document are drawn from.
public struct DecorationInput {
    public var layout: MarkdownLayout
    public var theme: NativeTheme
    public var storage: NSTextStorage
    public var layoutManager: NSLayoutManager
    public var textContainer: NSTextContainer
    /// The text container's origin in view coordinates.
    public var origin: CGPoint
    /// Whether a reveal unit's markup is currently shown.
    public var isRevealed: (NSRange) -> Bool
    public var isHidden: (Int) -> Bool
    public var images: ImageStore
    /// The size a loaded block image is drawn at; nil while loading or failed.
    public var blockImageSize: (MarkdownLayout.BlockImage) -> CGSize?
    /// The size a loaded inline image is drawn at; nil while loading or failed.
    public var inlineImageSize: (MarkdownLayout.InlineImage) -> CGSize?
    /// Block images are styled as inline images (a table cell): none is
    /// drawn as a block, loaded or failed.
    public var blockImagesInline: Bool
    /// A rendered diagram's picture and the size it is drawn at; nil while
    /// rendering or after a failure (its source shows).
    public var diagramImage: (MarkdownLayout.Diagram) -> (image: PlatformImage, size: CGSize)?
    /// Inline code runs that get a pill.
    public var codePillRuns: [MarkdownLayout.StyleRun]
    /// A rect moved (not resized) so its origin sits on a device pixel.
    public var pixelAlign: (CGRect) -> CGRect

    public init(layout: MarkdownLayout, theme: NativeTheme, storage: NSTextStorage, layoutManager: NSLayoutManager,
                textContainer: NSTextContainer, origin: CGPoint, isRevealed: @escaping (NSRange) -> Bool,
                isHidden: @escaping (Int) -> Bool, images: ImageStore,
                blockImageSize: @escaping (MarkdownLayout.BlockImage) -> CGSize?,
                inlineImageSize: @escaping (MarkdownLayout.InlineImage) -> CGSize? = { _ in nil },
                blockImagesInline: Bool = false,
                diagramImage: @escaping (MarkdownLayout.Diagram) -> (image: PlatformImage, size: CGSize)? = { _ in nil },
                codePillRuns: [MarkdownLayout.StyleRun], pixelAlign: @escaping (CGRect) -> CGRect) {
        self.layout = layout
        self.theme = theme
        self.storage = storage
        self.layoutManager = layoutManager
        self.textContainer = textContainer
        self.origin = origin
        self.isRevealed = isRevealed
        self.isHidden = isHidden
        self.images = images
        self.blockImageSize = blockImageSize
        self.inlineImageSize = inlineImageSize
        self.blockImagesInline = blockImagesInline
        self.diagramImage = diagramImage
        self.codePillRuns = codePillRuns
        self.pixelAlign = pixelAlign
    }
}

/// What the text system doesn't draw itself, behind the text: code-block
/// backgrounds, inline-code pills, block and inline images, quote rules,
/// list bullets and checkboxes, point-comment markers. Drawn into the
/// current graphics context, in the view's flipped coordinates.
@MainActor
public enum DocumentDecorations {
    public static func draw(_ input: DecorationInput, in rect: CGRect) {
        guard let context = currentContext() else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // AppKit's NSBezierPath defaults: curves flattened this finely
        // rasterize as the Mac view's shapes always have.
        context.setFlatness(0.6)
        context.setLineJoin(.miter)
        context.setLineCap(.butt)
        context.setMiterLimit(10)
        let lm = input.layoutManager, tc = input.textContainer, storage = input.storage
        let theme = input.theme, origin = input.origin
        // Whole source lines: hidden glyphs at a line's start (a list marker,
        // an image's source) sit on the fragment before, so a strip redrawn
        // while scrolling may hold only the line's visible rest or newline.
        let visible = (storage.string as NSString).lineRange(for: lm.characterRange(
            forGlyphRange: lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc),
            actualGlyphRange: nil))
        context.setFillColor(theme.paperDeep.cgColor)
        let shownDiagrams = input.layout.diagrams.filter {
            NSIntersectionRange($0.range, visible).length > 0 && NSMaxRange($0.range) <= storage.length
                && !input.isRevealed($0.range) && input.diagramImage($0) != nil
        }
        for block in input.layout.codeBlocks where NSIntersectionRange(block.range, visible).length > 0 && block.body.length > 0
            && !shownDiagrams.contains(where: { $0.range == block.range }) {
            let glyphs = lm.glyphRange(forCharacterRange: block.body, actualCharacterRange: nil)
            var box = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            box.origin.x = origin.x - 12
            box.size.width = tc.size.width + 24
            box.origin.y += origin.y - 8
            box.size.height += 16
            fill(roundedRect: box, radius: 6, in: context)
        }
        // Inline code: a pill hugging the code font around its baseline, per line.
        let pad = theme.mono.pointSize * 0.14
        for run in input.codePillRuns where NSIntersectionRange(run.range, visible).length > 0 {
            let glyphs = lm.glyphRange(forCharacterRange: run.range, actualCharacterRange: nil)
            var g = glyphs.location
            while g < NSMaxRange(glyphs) {
                var lineGlyphs = NSRange()
                let fragment = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &lineGlyphs)
                let part = NSIntersectionRange(glyphs, lineGlyphs)
                guard part.length > 0 else { break }
                let extent = lm.boundingRect(forGlyphRange: part, in: tc)
                let baseline = fragment.minY + lm.location(forGlyphAt: part.location).y
                let pill = CGRect(x: extent.minX - 2 + origin.x,
                                  y: baseline - theme.mono.ascender - pad + origin.y,
                                  width: extent.width + 4,
                                  height: theme.mono.ascender - theme.mono.descender + 2 * pad)
                fill(roundedRect: pill, radius: 4, in: context)
                g = NSMaxRange(part)
            }
        }
        drawImages(input, visible: visible)
        drawDiagrams(input, shownDiagrams)
        drawInlineImages(input, visible: visible)
        drawListsAndQuotes(input, visible: visible, in: context)
        drawPointMarkers(input, visible: visible, in: context)
    }

    /// Draw each shown block image into the line its hidden source reserves;
    /// a failed one shows its alt text instead.
    private static func drawImages(_ input: DecorationInput, visible: NSRange) {
        guard !input.blockImagesInline else { return }
        let lm = input.layoutManager, storage = input.storage, theme = input.theme, origin = input.origin
        for image in input.layout.blockImages
        where NSIntersectionRange(image.range, visible).length > 0 && NSMaxRange(image.range) <= storage.length
            && !input.isRevealed(image.range) {
            let fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: image.range.location),
                                               effectiveRange: nil)
            let x = fragment.minX + input.textContainer.lineFragmentPadding + origin.x
            if let size = input.blockImageSize(image), let picture = input.images.image(for: image.url) {
                // On whole device pixels: the lines above can leave the
                // fragment at a fractional point, smearing every edge.
                drawImage(picture, in: input.pixelAlign(CGRect(x: x, y: fragment.minY + origin.y + theme.body.pointSize / 2,
                                                               width: size.width, height: size.height)))
            } else if input.images.state(for: image.url) == .failed {
                let label = image.alt.isEmpty ? image.url : image.alt
                let font = theme.body.adding(.italic)
                let y = fragment.minY + origin.y + (fragment.height - lineBoxHeight(font)) / 2
                ("▨ " + label as NSString).draw(at: CGPoint(x: x, y: y),
                                                withAttributes: [.font: font, .foregroundColor: theme.muted])
            }
        }
    }

    /// Draw each shown diagram where `diagramRect` places it.
    private static func drawDiagrams(_ input: DecorationInput, _ diagrams: [MarkdownLayout.Diagram]) {
        for diagram in diagrams {
            guard let (picture, _) = input.diagramImage(diagram), let rect = diagramRect(input, diagram) else { continue }
            drawImage(picture, in: input.pixelAlign(rect))
        }
    }

    /// Where a shown diagram is drawn: centred in the line its hidden
    /// source reserves. That line is all hidden glyphs, which TextKit puts
    /// on the line before: the reserved height is on the line at its newline.
    public static func diagramRect(_ input: DecorationInput, _ diagram: MarkdownLayout.Diagram) -> CGRect? {
        guard let size = input.diagramImage(diagram)?.size, NSMaxRange(diagram.range) <= input.storage.length else { return nil }
        let lm = input.layoutManager, tc = input.textContainer, origin = input.origin
        let text = input.storage.string as NSString
        let newline = max(diagram.range.location,
                          NSMaxRange(text.lineRange(for: NSRange(location: diagram.range.location, length: 0))) - 1)
        let fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: newline), effectiveRange: nil)
        let column = tc.size.width - 2 * tc.lineFragmentPadding
        return CGRect(x: origin.x + tc.lineFragmentPadding + max(0, (column - size.width) / 2),
                      y: fragment.minY + origin.y + input.theme.body.pointSize / 2,
                      width: size.width, height: size.height)
    }

    /// Draw each shown inline image over its carrier "!" (the room its kern
    /// keeps), bottom on the line's baseline. Block images styled inline
    /// (in a table cell) are drawn here too.
    private static func drawInlineImages(_ input: DecorationInput, visible: NSRange) {
        let lm = input.layoutManager, storage = input.storage, origin = input.origin
        let scope = NSIntersectionRange(visible, NSRange(location: 0, length: storage.length))
        storage.enumerateAttribute(.tvmvImageCarrier, in: scope) { value, run, _ in
            guard let url = value as? String else { return }
            for location in run.location..<NSMaxRange(run) {
                let image = input.layout.inlineImages.first { $0.range.location == location }
                    ?? input.layout.blockImages.first { $0.range.location == location }.map(DocumentStyler.inlineImage)
                guard let image, image.url == url, let size = input.inlineImageSize(image),
                      let picture = input.images.image(for: url) else { continue }
                let glyph = lm.glyphIndexForCharacter(at: location)
                let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let at = lm.location(forGlyphAt: glyph)
                let baseline = fragment.minY + at.y + origin.y
                drawImage(picture, in: input.pixelAlign(CGRect(x: fragment.minX + at.x + origin.x, y: baseline - size.height,
                                                               width: size.width, height: size.height)))
            }
        }
    }

    /// Bullets, numbers, checkboxes and quote rules, in the indent the styler left.
    private static func drawListsAndQuotes(_ input: DecorationInput, visible: NSRange, in context: CGContext) {
        let lm = input.layoutManager, storage = input.storage, theme = input.theme, origin = input.origin
        let em = theme.body.pointSize
        for quote in input.layout.quoteLines where NSLocationInRange(quote.prefix.location, visible)
            && NSMaxRange(quote.prefix) <= storage.length && !input.isRevealed(quote.prefix) {
            let at = min(NSMaxRange(quote.prefix), max(0, storage.length - 1))
            let fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: at), effectiveRange: nil)
            context.setFillColor(theme.muted.withAlphaComponent(0.45).cgColor)
            for k in 0..<quote.level {
                context.fill(CGRect(x: origin.x + input.textContainer.lineFragmentPadding + CGFloat(k) * 1.2 * em + 0.2 * em,
                                    y: fragment.minY + origin.y, width: 3, height: fragment.height))
            }
        }
        for item in input.layout.listItems where NSLocationInRange(item.marker.location, visible)
            && !input.isRevealed(item.marker) {
            guard let g = DocumentGeometry.listItem(item, input) else { continue }
            if let task = item.task, let box = DocumentGeometry.taskBox(item, input) {
                let path = roundedRect(box, radius: 3)
                if task {
                    context.setFillColor(theme.accent.cgColor)
                    context.addPath(path)
                    context.fillPath()
                    context.move(to: CGPoint(x: box.minX + box.width * 0.22, y: box.midY))
                    context.addLine(to: CGPoint(x: box.minX + box.width * 0.42, y: box.maxY - box.height * 0.25))
                    context.addLine(to: CGPoint(x: box.maxX - box.width * 0.2, y: box.minY + box.height * 0.25))
                    context.setLineWidth(1.6)
                    context.setStrokeColor(theme.paper.cgColor)
                    context.strokePath()
                } else {
                    context.addPath(path)
                    context.setLineWidth(1.2)
                    context.setStrokeColor(theme.muted.cgColor)
                    context.strokePath()
                }
                continue
            }
            let label: String
            if item.ordered {
                label = (storage.string as NSString).substring(with: item.bullet)
            } else {
                label = ["•", "◦", "▪"][min(item.level, 2)]
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: theme.body, .foregroundColor: theme.muted]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: CGPoint(x: g.textX - size.width - 0.45 * em, y: g.baseline - theme.body.ascender),
                                     withAttributes: attributes)
        }
    }

    /// A point comment: a small accent bubble, superscript, in the room its
    /// clear "[" carrier keeps (not while its source is revealed).
    private static func drawPointMarkers(_ input: DecorationInput, visible: NSRange, in context: CGContext) {
        let lm = input.layoutManager, storage = input.storage, theme = input.theme, origin = input.origin
        let em = theme.body.pointSize
        context.setFillColor(theme.accent.cgColor)
        for run in input.layout.styles where NSLocationInRange(run.range.location, visible) && run.range.location < storage.length {
            guard case .review(.pointMarker, _) = run.style,
                  storage.attribute(.foregroundColor, at: run.range.location, effectiveRange: nil) as? PlatformColor == .clear
            else { continue }
            let glyph = lm.glyphIndexForCharacter(at: run.range.location)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let x = lm.location(forGlyphAt: glyph).x + fragment.minX + origin.x
            let baseline = fragment.minY + lm.location(forGlyphAt: glyph).y + origin.y
            let side = em * 0.5
            let bubble = CGRect(x: x + em * 0.05, y: baseline - theme.body.ascender * 0.95, width: side, height: side * 0.8)
            fill(roundedRect: bubble, radius: side * 0.3, in: context)
        }
    }

    /// A rounded rect path; the radius shrinks to fit a small rect, as AppKit's does.
    /// On macOS, AppKit's own curves: CGPath's differ in the last bit of
    /// antialiasing, and the Mac view's shapes stay exactly as they were.
    private static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        #if os(macOS)
        return NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).cgPath
        #else
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        #endif
    }

    private static func fill(roundedRect rect: CGRect, radius: CGFloat, in context: CGContext) {
        context.addPath(roundedRect(rect, radius: radius))
        context.fillPath()
    }

    private static func currentContext() -> CGContext? {
        #if os(macOS)
        NSGraphicsContext.current?.cgContext
        #else
        UIGraphicsGetCurrentContext()
        #endif
    }

    /// The height of a line of `font` (AppKit's bounding rect for the font).
    private static func lineBoxHeight(_ font: PlatformFont) -> CGFloat {
        #if os(macOS)
        font.boundingRectForFont.height
        #else
        font.lineHeight
        #endif
    }

    private static func drawImage(_ image: PlatformImage, in rect: CGRect) {
        #if os(macOS)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        #else
        image.draw(in: rect)
        #endif
    }
}
