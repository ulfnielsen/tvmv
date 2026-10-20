import AppKit
import TVMVCore

extension NSAttributedString.Key {
    /// Markup hidden by the layout-manager delegate (null glyphs).
    static let tvmvHidden = NSAttributedString.Key("tvmvHidden")
    /// Exempt from spelling and grammar checking.
    static let tvmvNoSpell = NSAttributedString.Key("tvmvNoSpell")
    /// Link destination; clicks follow it when read-only or with ⌘.
    static let tvmvLink = NSAttributedString.Key("tvmvLink")
    /// A soft line break inside a paragraph: laid out as a space, so the
    /// paragraph reflows like the web reader's.
    static let tvmvSoftBreak = NSAttributedString.Key("tvmvSoftBreak")
}

/// Fonts, colors and measure for the native view: the paper & ink palette
/// from app.css, expressed as AppKit values.
struct NativeTheme: Equatable {
    var body: NSFont
    var mono: NSFont
    var ink: NSColor
    var inkSoft: NSColor
    var muted: NSColor
    var accent: NSColor
    var paper: NSColor
    var paperDeep: NSColor
    /// Text column width in points; nil means full width.
    var columnWidth: CGFloat?
    /// Minimum horizontal padding either side of the column (app.css --tvmv-pad).
    var padding: CGFloat = 68

    init(bodyFamily: String, monoFamily: String, size: CGFloat, measure: Double, fullWidth: Bool, dark: Bool) {
        body = NSFont(name: bodyFamily, size: size)
            ?? NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        mono = NSFont(name: monoFamily, size: size * 0.86)
            ?? .monospacedSystemFont(ofSize: size * 0.86, weight: .regular)
        func hex(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        if dark {
            paper = hex(0x181410); paperDeep = hex(0x221C16); ink = hex(0xECE3D3)
            inkSoft = hex(0xCBB89B); muted = hex(0x9C876A); accent = hex(0xE2693B)
        } else {
            paper = hex(0xFBF8F2); paperDeep = hex(0xF4EFE3); ink = hex(0x2A1810)
            inkSoft = hex(0x5A3D2A); muted = hex(0x8A7359); accent = hex(0xB83F12)
        }
        let zero = ("0" as NSString).size(withAttributes: [.font: body]).width
        columnWidth = fullWidth ? nil : CGFloat(measure) * zero
    }

    /// app.css: body line-height 1.7. Gaps between paragraphs come from
    /// the blank lines that separate them (`blankLineParagraph`).
    var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = body.pointSize * 1.7
        p.maximumLineHeight = body.pointSize * 1.7
        return p
    }

    /// A blank line between blocks is the 1em paragraph margin of app.css.
    var blankLineParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = body.pointSize
        p.maximumLineHeight = body.pointSize
        return p
    }

    /// app.css headings: line-height 1.25, extra room above (margin-top 1.6em,
    /// of which the preceding blank line supplies 1em).
    func headingParagraph(_ level: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let height = headingFont(level).pointSize * 1.25
        p.minimumLineHeight = height
        p.maximumLineHeight = height
        p.paragraphSpacingBefore = body.pointSize * 0.6
        return p
    }

    /// Code lines: no gaps between lines; room above the first line and
    /// below the last for the block background.
    func codeParagraph(first: Bool, last: Bool) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        p.paragraphSpacingBefore = first ? body.pointSize * 0.7 : 0
        p.paragraphSpacing = last ? body.pointSize * 1.1 : 0
        return p
    }

    static var collapsedParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = 0.01
        p.maximumLineHeight = 0.01
        return p
    }

    var base: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: ink, .paragraphStyle: paragraphStyle]
    }

    /// app.css heading scale: h1 2.0em … h6 0.85em, regular weight (400) —
    /// the serif's display sizes carry the hierarchy, not boldness.
    func headingFont(_ level: Int) -> NSFont {
        let scale: [CGFloat] = [2.0, 1.5, 1.28, 1.1, 0.95, 0.85]
        return body.withSize(body.pointSize * scale[max(1, min(level, 6)) - 1])
    }
}

extension NativeTheme {
    /// The theme for the current settings. `dark` is the resolved appearance
    /// (Settings' light/dark, or the system's when set to auto).
    @MainActor
    init(settings: AppSettings, dark: Bool) {
        self.init(bodyFamily: settings.bodyFont, monoFamily: settings.monoFont,
                  size: CGFloat(settings.baseSize), measure: settings.measure,
                  fullWidth: settings.fullWidth, dark: dark)
    }

    /// Window-chrome tint: the paper color lightened, as the web reader did.
    var chromeColor: RGBAColor {
        let c = paper.usingColorSpace(.sRGB) ?? paper
        return RGBAColor(red: Double(c.redComponent), green: Double(c.greenComponent),
                         blue: Double(c.blueComponent)).blended(fraction: 0.16, of: .white)
    }
}
