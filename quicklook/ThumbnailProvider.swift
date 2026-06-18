import Cocoa
import CoreText
import QuickLookThumbnailing

/// QuickLook thumbnail extension principal class.
///
/// Renders a Markdown file into a small "page overview" thumbnail using ONLY
/// Core Graphics + Core Text — NO WKWebView and NO NSWindow. Those are
/// unreliable / blocked inside the restricted thumbnail XPC sandbox, and when
/// the old WKWebView+snapshot render failed QuickLook fell back to the
/// preview-derived auto thumbnail (a 100% crop of just the big top heading).
///
/// The pipeline is now:
///   bytes -> MarkdownText.decode -> lightweight markdown layout (CTFramesetter)
///   -> draw a wide 8.5:11 logical "page" of small text -> scale DOWN to fill
///      the thumbnail context width.
/// Because the logical page is wide (~820pt) and the thumbnail small, body text
/// shrinks to a realistic "page of paper" scale and several sections are
/// visible — a page overview, not one giant heading.
///
/// All work is synchronous CPU work, so the handler is called synchronously.
/// The `@objc(ThumbnailProvider)` name MUST match the Info.plist
/// `NSExtensionPrincipalClass`.
@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {

    // The logical "page" we lay text into. 8.5:11 (US Letter) aspect, wide
    // enough that body text shrinks to a realistic page scale in the thumbnail.
    static let pageWidth: CGFloat = 820
    static let pageHeight: CGFloat = 820 * 11.0 / 8.5  // ≈ 1061

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL
        let text: String
        do {
            let data = try Data(contentsOf: url)
            text = MarkdownText.decode(data).text
        } catch {
            handler(nil, error)
            return
        }

        // Pure CPU: lay out + draw the logical page, then build the reply that
        // scales it into the requested thumbnail context. No async, no window.
        let reply = Self.makeReply(text: text, request: request)
        handler(reply, nil)
    }

    /// Build a QLThumbnailReply whose context is a portrait page that fits
    /// `request.maximumSize`, honoring `request.scale`. The logical page is
    /// drawn scaled to FILL the context width, top-aligned (so the thumbnail
    /// shows the top of the document, like the first part of a page).
    static func makeReply(
        text: String,
        request: QLFileThumbnailRequest
    ) -> QLThumbnailReply {
        let maxSize = request.maximumSize           // points
        let scale = request.scale                   // pixels per point

        // Fit an 8.5:11 portrait page inside the requested maximum (in points).
        let pageAspect = pageHeight / pageWidth      // height / width ≈ 1.294
        var w = maxSize.width
        var h = w * pageAspect
        if h > maxSize.height {
            h = maxSize.height
            w = h / pageAspect
        }
        // QLThumbnailReply(contextSize:) is in POINTS; QuickLook multiplies by
        // request.scale internally for the backing store. We pass points.
        let contextSize = CGSize(width: max(1, w), height: max(1, h))

        return QLThumbnailReply(contextSize: contextSize) { (ctx: CGContext) -> Bool in
            Self.drawPage(text: text, into: ctx, contextSize: contextSize)
            _ = scale  // applied by QuickLook to the context backing store
            return true
        }
    }

    /// Draw the logical page laid out top-down, scaled to fill `contextSize`'s
    /// width and top-aligned. Shared by the reply block and the test harness.
    static func drawPage(text: String, into ctx: CGContext, contextSize: CGSize) {
        // Paper fill so transparent edges read as a page of paper.
        ctx.saveGState()
        ctx.setFillColor(PageThumbnailRenderer.paper.cgColor)
        ctx.fill(CGRect(origin: .zero, size: contextSize))
        ctx.restoreGState()

        // Map the wide logical page onto the context: scale by width, top-align.
        // CGContext origin is bottom-left. The logical page is laid out with its
        // own bottom-left origin too (Core Text flips internally below), so we
        // translate the page so its TOP sits at the context's TOP, then scale.
        let drawScale = contextSize.width / pageWidth
        let drawnHeight = pageHeight * drawScale

        ctx.saveGState()
        // Top-align: move origin so the page's top edge is at the context top.
        ctx.translateBy(x: 0, y: contextSize.height - drawnHeight)
        ctx.scaleBy(x: drawScale, y: drawScale)
        PageThumbnailRenderer.draw(text: text,
                                   in: ctx,
                                   pageSize: CGSize(width: pageWidth, height: pageHeight))
        ctx.restoreGState()
    }
}

/// Lightweight markdown -> attributed-string layout, drawn with Core Text.
///
/// Deliberately NOT full cmark/HTML fidelity — a tiny thumbnail can't show it.
/// We parse line-by-line into a single attributed string with the warm theme,
/// then lay it out top-down with CTFramesetter clipped to the page height.
enum PageThumbnailRenderer {

    // ---- Warm "paper & ink" theme (matches app.css tokens) ----------------
    static let paper = NSColor(srgbRed: 0xFB/255, green: 0xF8/255, blue: 0xF2/255, alpha: 1)
    static let ink   = NSColor(srgbRed: 0x2A/255, green: 0x18/255, blue: 0x10/255, alpha: 1)
    static let inkSoft = NSColor(srgbRed: 0x5A/255, green: 0x3D/255, blue: 0x2A/255, alpha: 1)
    static let accent = NSColor(srgbRed: 0xB8/255, green: 0x3F/255, blue: 0x12/255, alpha: 1)
    static let muted  = NSColor(srgbRed: 0x8A/255, green: 0x73/255, blue: 0x59/255, alpha: 1)
    static let codeBg = NSColor(srgbRed: 0xF4/255, green: 0xEF/255, blue: 0xE3/255, alpha: 1)

    // Base body size on the ~820pt-wide logical page.
    static let baseSize: CGFloat = 13
    static let pad: CGFloat = 56   // page margins

    /// Render the page to an NSImage (used by the harness).
    static func renderPageImage(text: String, pageSize: CGSize) -> NSImage {
        let image = NSImage(size: pageSize)
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }
        ctx.setFillColor(paper.cgColor)
        ctx.fill(CGRect(origin: .zero, size: pageSize))
        draw(text: text, in: ctx, pageSize: pageSize)
        image.unlockFocus()
        return image
    }

    /// Draw the laid-out markdown into `ctx` over a `pageSize` logical page.
    /// Assumes the caller has already filled the paper background. Uses a
    /// bottom-left origin context (standard CGContext); Core Text draws upright.
    static func draw(text: String, in ctx: CGContext, pageSize: CGSize) {
        let attributed = buildAttributedString(from: text)

        let contentWidth = pageSize.width - pad * 2
        let contentRect = CGRect(x: pad, y: pad,
                                 width: contentWidth,
                                 height: pageSize.height - pad * 2)

        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)

        // First pass: lay out to discover line origins so we can paint the
        // code-block backgrounds behind their lines, then draw the text.
        let path = CGPath(rect: contentRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter,
                                             CFRangeMake(0, 0),
                                             path, nil)

        ctx.saveGState()
        drawCodeBackgrounds(frame: frame, attributed: attributed, ctx: ctx)
        // Core Text expects an unflipped (bottom-left origin) context; our
        // context already is one, so draw directly.
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    // ---- Markdown -> attributed string ------------------------------------

    private enum LineKind {
        case heading(level: Int)
        case bullet
        case ordered(marker: String)
        case codeFence       // a ``` line itself (skipped)
        case code            // inside a fenced block
        case blank
        case body
    }

    static func buildAttributedString(from raw: String) -> NSAttributedString {
        let bodyFont = font(serif: true, size: baseSize, bold: false)
        let result = NSMutableAttributedString()

        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var inCode = false
        // Cap total lines so a huge document doesn't waste layout effort; the
        // page clip discards overflow anyway, but this bounds CPU.
        let maxLines = 400

        for (idx, rawLine) in lines.enumerated() {
            if idx >= maxLines { break }
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block toggling.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCode.toggle()
                continue  // don't render the fence line itself
            }
            if inCode {
                append(result, text: line.isEmpty ? " " : line,
                       attrs: codeAttributes(), paragraph: codeParagraph())
                continue
            }

            if trimmed.isEmpty {
                // Paragraph spacing via a blank line.
                append(result, text: " ", attrs: [.font: smallSpacerFont()],
                       paragraph: spacerParagraph())
                continue
            }

            switch classify(trimmed) {
            case .heading(let level):
                let content = stripHeadingMarker(trimmed)
                let clean = stripInline(content)
                let size = headingSize(for: level)
                let color = level <= 2 ? ink : inkSoft
                append(result, text: clean,
                       attrs: [.font: font(serif: true, size: size, bold: true),
                               .foregroundColor: color],
                       paragraph: headingParagraph(level: level))
            case .bullet:
                let content = stripBulletMarker(trimmed)
                let clean = stripInline(content)
                append(result, text: "•  " + clean,
                       attrs: [.font: bodyFont, .foregroundColor: ink],
                       paragraph: listParagraph())
            case .ordered(let marker):
                let content = stripOrderedMarker(trimmed)
                let clean = stripInline(content)
                let mutable = NSMutableAttributedString()
                mutable.append(NSAttributedString(string: marker + "  ",
                    attributes: [.font: font(serif: true, size: baseSize, bold: false),
                                 .foregroundColor: muted,
                                 .paragraphStyle: listParagraph()]))
                mutable.append(NSAttributedString(string: clean,
                    attributes: [.font: bodyFont, .foregroundColor: ink,
                                 .paragraphStyle: listParagraph()]))
                result.append(mutable)
                result.append(NSAttributedString(string: "\n"))
            case .body:
                // Blockquote marker -> a soft indented quote.
                if trimmed.hasPrefix(">") {
                    let content = stripInline(stripQuoteMarker(trimmed))
                    append(result, text: content,
                           attrs: [.font: font(serif: true, size: baseSize, bold: false),
                                   .foregroundColor: inkSoft],
                           paragraph: quoteParagraph())
                } else {
                    let clean = stripInline(trimmed)
                    append(result, text: clean,
                           attrs: [.font: bodyFont, .foregroundColor: ink],
                           paragraph: bodyParagraph())
                }
            case .code, .codeFence, .blank:
                break
            }
        }

        return result
    }

    private static func append(_ s: NSMutableAttributedString,
                               text: String,
                               attrs: [NSAttributedString.Key: Any],
                               paragraph: NSParagraphStyle) {
        var a = attrs
        a[.paragraphStyle] = paragraph
        s.append(NSAttributedString(string: text, attributes: a))
        s.append(NSAttributedString(string: "\n"))
    }

    // ---- Line classification ----------------------------------------------

    private static func classify(_ trimmed: String) -> LineKind {
        if trimmed.hasPrefix("#") {
            var level = 0
            for ch in trimmed {
                if ch == "#" { level += 1 } else { break }
            }
            // A run of # followed by a space is a heading (cap at 6).
            if level >= 1 && level <= 6,
               trimmed.dropFirst(level).first == " " {
                return .heading(level: level)
            }
        }
        if let m = trimmed.first, (m == "-" || m == "*" || m == "+"),
           trimmed.dropFirst().first == " " {
            return .bullet
        }
        if let marker = orderedMarker(trimmed) {
            return .ordered(marker: marker)
        }
        return .body
    }

    /// Returns the numeric marker (e.g. "1.") if the line is an ordered item.
    private static func orderedMarker(_ trimmed: String) -> String? {
        var digits = ""
        for ch in trimmed {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        guard !digits.isEmpty else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        if let sep = rest.first, (sep == "." || sep == ")"),
           rest.dropFirst().first == " " {
            return digits + "."
        }
        return nil
    }

    // ---- Marker stripping --------------------------------------------------

    private static func stripHeadingMarker(_ trimmed: String) -> String {
        var s = Substring(trimmed)
        while s.first == "#" { s = s.dropFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func stripBulletMarker(_ trimmed: String) -> String {
        let s = trimmed.dropFirst()  // the - * + marker
        let content = String(s).trimmingCharacters(in: .whitespaces)
        // Task list checkbox: "[ ] " / "[x] "
        if content.hasPrefix("[") && content.count >= 3 {
            let arr = Array(content)
            if arr[2] == "]" {
                let checked = arr[1] == "x" || arr[1] == "X"
                let rest = String(arr.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                return (checked ? "☑ " : "☐ ") + rest
            }
        }
        return content
    }

    private static func stripOrderedMarker(_ trimmed: String) -> String {
        var s = Substring(trimmed)
        while let f = s.first, f.isNumber { s = s.dropFirst() }
        if let f = s.first, f == "." || f == ")" { s = s.dropFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func stripQuoteMarker(_ trimmed: String) -> String {
        var s = Substring(trimmed)
        while s.first == ">" {
            s = s.dropFirst()
            if s.first == " " { s = s.dropFirst() }
        }
        return String(s)
    }

    /// Strip inline markdown markers for cleanliness in a tiny thumbnail.
    /// Handles **bold**, *italic*, _italic_, `code`, ~~strike~~, and
    /// [text](url) / <url> link forms (keeping the visible text).
    static func stripInline(_ input: String) -> String {
        var s = input

        // [text](url) -> text   (also ![alt](url) image -> alt)
        s = replaceRegex(s, pattern: "!?\\[([^\\]]*)\\]\\([^)]*\\)", template: "$1")
        // <https://url> -> url
        s = replaceRegex(s, pattern: "<((?:https?|mailto)[^>]*)>", template: "$1")
        // Reference-style [text][ref] -> text
        s = replaceRegex(s, pattern: "\\[([^\\]]*)\\]\\[[^\\]]*\\]", template: "$1")

        // Emphasis / code / strike markers — remove the delimiters only.
        for marker in ["**", "__", "~~", "*", "_", "`"] {
            s = s.replacingOccurrences(of: marker, with: "")
        }
        return s
    }

    private static func replaceRegex(_ s: String, pattern: String, template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    // ---- Fonts -------------------------------------------------------------

    private static func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize * 1.85
        case 2: return baseSize * 1.45
        case 3: return baseSize * 1.2
        default: return baseSize * 1.05
        }
    }

    /// Source Serif 4 for body/headings (warm theme), falling back to Georgia
    /// then the system serif if unavailable in the sandbox. Menlo for code.
    private static func font(serif: Bool, size: CGFloat, bold: Bool) -> NSFont {
        if serif {
            let names = bold
                ? ["Source Serif 4 Semibold", "Source Serif 4", "Georgia-Bold", "Georgia"]
                : ["Source Serif 4", "Georgia"]
            for name in names {
                if let f = NSFont(name: name, size: size) {
                    if bold {
                        let weighted = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
                        return weighted
                    }
                    return f
                }
            }
            // System serif fallback.
            let base = NSFont.systemFont(ofSize: size,
                                         weight: bold ? .semibold : .regular)
            if let serifDesc = base.fontDescriptor
                .withDesign(.serif) {
                return NSFont(descriptor: serifDesc, size: size) ?? base
            }
            return base
        }
        return NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func codeFont() -> NSFont {
        NSFont(name: "Menlo", size: baseSize * 0.9)
            ?? NSFont.monospacedSystemFont(ofSize: baseSize * 0.9, weight: .regular)
    }

    private static func smallSpacerFont() -> NSFont {
        NSFont(name: "Georgia", size: baseSize * 0.5)
            ?? NSFont.systemFont(ofSize: baseSize * 0.5)
    }

    private static func codeAttributes() -> [NSAttributedString.Key: Any] {
        [.font: codeFont(), .foregroundColor: ink]
    }

    // ---- Paragraph styles --------------------------------------------------

    private static func bodyParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        p.paragraphSpacing = 4
        p.lineBreakMode = .byWordWrapping
        return p
    }

    private static func headingParagraph(level: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = level <= 2 ? 12 : 8
        p.paragraphSpacing = 4
        p.lineBreakMode = .byWordWrapping
        return p
    }

    private static func listParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 14
        p.headIndent = 24
        p.lineSpacing = 2
        p.paragraphSpacing = 2
        p.lineBreakMode = .byWordWrapping
        return p
    }

    private static func quoteParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 16
        p.headIndent = 16
        p.lineSpacing = 2
        p.paragraphSpacing = 4
        p.lineBreakMode = .byWordWrapping
        return p
    }

    private static func codeParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 14
        p.headIndent = 14
        p.lineSpacing = 1
        p.lineBreakMode = .byTruncatingTail  // keep code on one line in a tiny page
        return p
    }

    private static func spacerParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 2
        return p
    }

    // ---- Code block backgrounds -------------------------------------------

    /// Paint a faint gray rounded box behind runs of code lines.
    private static func drawCodeBackgrounds(frame: CTFrame,
                                            attributed: NSAttributedString,
                                            ctx: CGContext) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)

        let codeFontName = codeFont().fontName
        let pathRect = boundingRect(of: frame)

        // Determine which lines are code by inspecting the run font at the
        // line's first character.
        var codeFlags = [Bool](repeating: false, count: lines.count)
        for (i, line) in lines.enumerated() {
            let range = CTLineGetStringRange(line)
            if range.length > 0,
               let font = attributed.attribute(.font, at: range.location,
                                                effectiveRange: nil) as? NSFont {
                codeFlags[i] = font.fontName == codeFontName
            }
        }

        // Group consecutive code lines into boxes.
        var i = 0
        while i < lines.count {
            if codeFlags[i] {
                var j = i
                while j + 1 < lines.count && codeFlags[j + 1] { j += 1 }
                // Box spans from top of line i to bottom of line j.
                let topLine = lines[i]
                let botLine = lines[j]
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                CTLineGetTypographicBounds(topLine, &ascent, &descent, &leading)
                let top = origins[i].y + ascent
                CTLineGetTypographicBounds(botLine, &ascent, &descent, &leading)
                let bottom = origins[j].y - descent
                let box = CGRect(x: pathRect.minX - 4,
                                 y: bottom - 3,
                                 width: pathRect.width + 8,
                                 height: (top - bottom) + 6)
                ctx.saveGState()
                let bez = CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5,
                                 transform: nil)
                ctx.addPath(bez)
                ctx.setFillColor(codeBg.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
                i = j + 1
            } else {
                i += 1
            }
        }
    }

    private static func boundingRect(of frame: CTFrame) -> CGRect {
        let path = CTFrameGetPath(frame)
        return path.boundingBoxOfPath
    }
}
