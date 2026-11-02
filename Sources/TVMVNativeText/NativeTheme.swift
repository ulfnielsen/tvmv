import CoreGraphics
import Foundation
import TVMVCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public extension NSAttributedString.Key {
    /// Markup hidden by the layout-manager delegate (null glyphs).
    static let tvmvHidden = NSAttributedString.Key("tvmvHidden")
    /// Exempt from spelling and grammar checking.
    static let tvmvNoSpell = NSAttributedString.Key("tvmvNoSpell")
    /// Link destination; clicks follow it when read-only or with ⌘.
    static let tvmvLink = NSAttributedString.Key("tvmvLink")
    /// A soft line break inside a paragraph: laid out as a space, so the
    /// paragraph reflows like the web reader's.
    static let tvmvSoftBreak = NSAttributedString.Key("tvmvSoftBreak")
    /// The review thread id of an anchor's text (or a point comment's carrier).
    static let tvmvReview = NSAttributedString.Key("tvmvReview")
}

/// Fonts, colors and measure for the native view: the paper & ink palette
/// from app.css, expressed as AppKit values.
public struct NativeTheme: Equatable {
    public var body: PlatformFont
    public var mono: PlatformFont
    public var ink: PlatformColor
    public var inkSoft: PlatformColor
    public var muted: PlatformColor
    public var accent: PlatformColor
    public var paper: PlatformColor
    public var paperDeep: PlatformColor
    /// Review markup: a commented range's background, inserted and deleted text.
    public var reviewHighlight: PlatformColor
    public var reviewInsert: PlatformColor
    public var reviewDelete: PlatformColor
    /// Text column width in points; nil means full width.
    public var columnWidth: CGFloat?
    /// Minimum horizontal padding either side of the column (app.css --tvmv-pad).
    public var padding: CGFloat = 68
    /// Paragraph alignment (table cells follow their column's alignment).
    public var textAlignment: NSTextAlignment = .natural

    public init(bodyFamily: String, monoFamily: String, size: CGFloat, measure: Double, fullWidth: Bool, dark: Bool) {
        body = PlatformFont(name: bodyFamily, size: size)
            ?? PlatformFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        mono = PlatformFont(name: monoFamily, size: size * 0.86)
            ?? .monospacedSystemFont(ofSize: size * 0.86, weight: .regular)
        func hex(_ v: UInt32) -> PlatformColor { .srgb(v) }
        if dark {
            paper = hex(0x181410); paperDeep = hex(0x221C16); ink = hex(0xECE3D3)
            inkSoft = hex(0xCBB89B); muted = hex(0x9C876A); accent = hex(0xE2693B)
            reviewHighlight = hex(0x8A6D10).withAlphaComponent(0.55)
            reviewInsert = hex(0x7FC48A); reviewDelete = hex(0xEF8A80)
        } else {
            paper = hex(0xFBF8F2); paperDeep = hex(0xF4EFE3); ink = hex(0x2A1810)
            inkSoft = hex(0x5A3D2A); muted = hex(0x8A7359); accent = hex(0xB83F12)
            reviewHighlight = hex(0xFFE27A).withAlphaComponent(0.6)
            reviewInsert = hex(0x2E7D32); reviewDelete = hex(0xB3261E)
        }
        let zero = ("0" as NSString).size(withAttributes: [.font: body]).width
        columnWidth = fullWidth ? nil : CGFloat(measure) * zero
    }

    /// app.css: body line-height 1.7. Gaps between paragraphs come from
    /// the blank lines that separate them (`blankLineParagraph`).
    public var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = body.pointSize * 1.7
        p.maximumLineHeight = body.pointSize * 1.7
        p.alignment = textAlignment
        return p
    }

    /// A blank line between blocks is the 1em paragraph margin of app.css.
    public var blankLineParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = body.pointSize
        p.maximumLineHeight = body.pointSize
        return p
    }

    /// app.css headings: line-height 1.25, extra room above (margin-top 1.6em,
    /// of which the preceding blank line supplies 1em).
    public func headingParagraph(_ level: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let height = headingFont(level).pointSize * 1.25
        p.minimumLineHeight = height
        p.maximumLineHeight = height
        p.paragraphSpacingBefore = body.pointSize * 0.6
        return p
    }

    /// Code lines: no gaps between lines; room above the first line and
    /// below the last for the block background.
    public func codeParagraph(first: Bool, last: Bool) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        p.paragraphSpacingBefore = first ? body.pointSize * 0.7 : 0
        p.paragraphSpacing = last ? body.pointSize * 1.1 : 0
        return p
    }

    public static var collapsedParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = 0.01
        p.maximumLineHeight = 0.01
        return p
    }

    public var base: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: ink, .paragraphStyle: paragraphStyle]
    }

    /// app.css heading scale: h1 2.0em … h6 0.85em, regular weight (400) —
    /// the serif's display sizes carry the hierarchy, not boldness.
    public func headingFont(_ level: Int) -> PlatformFont {
        let scale: [CGFloat] = [2.0, 1.5, 1.28, 1.1, 0.95, 0.85]
        return body.withSize(body.pointSize * scale[max(1, min(level, 6)) - 1])
    }
}

extension NativeTheme {
    /// The theme for the current settings. `dark` is the resolved appearance
    /// (Settings' light/dark, or the system's when set to auto).
    @MainActor
    public init(settings: AppSettings, dark: Bool) {
        self.init(bodyFamily: settings.bodyFont, monoFamily: settings.monoFont,
                  size: CGFloat(settings.baseSize), measure: settings.measure,
                  fullWidth: settings.fullWidth, dark: dark)
    }

    /// Window-chrome tint: the paper color lightened, as the web reader did.
    public var chromeColor: RGBAColor {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let c = paper.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil)?.components
            ?? paper.cgColor.components ?? [0, 0, 0]
        return RGBAColor(red: Double(c[0]), green: Double(c[1]),
                         blue: Double(c[2])).blended(fraction: 0.16, of: .white)
    }
}
