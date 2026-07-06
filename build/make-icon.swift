import AppKit
import Foundation

// tvmv icon — "Serif M on paper, over greeked text"
// Offscreen 1024x1024 RGBA icon: elegant serif capital "M" in dark ink
// on a warm cream-to-parchment gradient tile, with faint paragraph bars
// behind the letter — a page of prose, matching tvtv's table-grid treatment.

let canvas: CGFloat = 1024
let inset: CGFloat = 100
let tileSize = canvas - inset * 2          // 824
let cornerRadius = tileSize * 0.2237       // ~184

// MARK: - Offscreen bitmap
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas),
    pixelsHigh: Int(canvas),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write("Failed to create bitmap rep\n".data(using: .utf8)!)
    exit(1)
}

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write("Failed to create graphics context\n".data(using: .utf8)!)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

// Transparent canvas
cg.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

let tileRect = NSRect(x: inset, y: inset, width: tileSize, height: tileSize)
let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: cornerRadius, yRadius: cornerRadius)

// MARK: - Drop shadow (drawn under the tile)
cg.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -12) // non-flipped: visually downward
shadow.set()
NSColor.white.setFill()   // opaque fill so the shadow has a solid caster
tilePath.fill()
cg.restoreGState()

// MARK: - Warm cream-to-parchment gradient fill
cg.saveGState()
tilePath.addClip()

let cream = NSColor(calibratedRed: 0.992, green: 0.972, blue: 0.929, alpha: 1.0)      // top: warm cream
let parchment = NSColor(calibratedRed: 0.945, green: 0.901, blue: 0.819, alpha: 1.0)  // bottom: parchment
let gradient = NSGradient(colors: [cream, parchment])!
// Top-to-bottom (top lighter). In non-flipped coords, angle -90 goes top->bottom.
gradient.draw(in: tileRect, angle: -90)

// MARK: - Soft inner vignette (paper character)
let vignetteRect = tileRect
let center = NSPoint(x: vignetteRect.midX, y: vignetteRect.midY)
let radial = NSGradient(colors: [
    NSColor.clear,
    NSColor(calibratedRed: 0.62, green: 0.54, blue: 0.40, alpha: 0.0),
    NSColor(calibratedRed: 0.50, green: 0.41, blue: 0.27, alpha: 0.16)
])!
radial.draw(fromCenter: center, radius: tileSize * 0.18,
            toCenter: center, radius: tileSize * 0.74,
            options: [])

// MARK: - Serif font resolver (shared by background text and the "M")
func resolveFont(size: CGFloat) -> NSFont {
    let candidates = ["Source Serif 4 Semibold", "SourceSerif4-Semibold",
                      "Source Serif 4", "Georgia-Bold", "Georgia"]
    for name in candidates {
        if let f = NSFont(name: name, size: size) { return f }
    }
    if #available(macOS 10.15, *) {
        return NSFont(descriptor:
            NSFont.systemFont(ofSize: size, weight: .semibold)
                .fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: size).fontDescriptor,
            size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }
    return NSFont.boldSystemFont(ofSize: size)
}

// MARK: - Faint lorem ipsum in the background
// A page of real prose behind the "M" — justified lorem ipsum in very light
// ink, filling most of the tile. Same warm-brown ink family as tvtv's grid.
let textInsetX = tileSize * 0.13
let textInsetY = tileSize * 0.085
let textRect = NSRect(
    x: tileRect.minX + textInsetX,
    y: tileRect.minY + textInsetY,
    width: tileSize - textInsetX * 2,
    height: tileSize - textInsetY * 2
)

let bodyInk = NSColor(calibratedRed: 0.42, green: 0.33, blue: 0.20, alpha: 0.55)
let headingInkColor = NSColor(calibratedRed: 0.42, green: 0.33, blue: 0.20, alpha: 0.65)

let bodyStyle = NSMutableParagraphStyle()
bodyStyle.alignment = .justified
bodyStyle.hyphenationFactor = 0.9
bodyStyle.paragraphSpacing = tileSize * 0.022

let lorem =
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do " +
    "eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim " +
    "ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut " +
    "aliquip ex ea commodo consequat.\n" +
    "Duis aute irure dolor in reprehenderit in voluptate velit esse " +
    "cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat " +
    "cupidatat non proident, sunt in culpa qui officia deserunt mollit " +
    "anim id est laborum. Sed ut perspiciatis unde omnis iste natus " +
    "error sit voluptatem accusantium doloremque laudantium, totam rem " +
    "aperiam, eaque ipsa quae ab illo inventore veritatis et quasi " +
    "architecto beatae vitae dicta sunt explicabo."

let page = NSMutableAttributedString()
page.append(NSAttributedString(
    string: "Lorem ipsum\n",
    attributes: [
        .font: resolveFont(size: tileSize * 0.058),
        .foregroundColor: headingInkColor,
        .paragraphStyle: bodyStyle,
    ]))
page.append(NSAttributedString(
    string: lorem,
    attributes: [
        .font: resolveFont(size: tileSize * 0.042),
        .foregroundColor: bodyInk,
        .paragraphStyle: bodyStyle,
    ]))
page.draw(with: textRect, options: [.usesLineFragmentOrigin])

cg.restoreGState()

// MARK: - Serif capital "M" glyph
let glyphFontSize = tileSize * 0.74
let inkColor = NSColor(calibratedRed: 0.149, green: 0.118, blue: 0.090, alpha: 1.0) // dark warm ink
let font = resolveFont(size: glyphFontSize)

let glyph = "M"
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: inkColor,
    .kern: 0.0
]
let attr = NSAttributedString(string: glyph, attributes: attrs)

// Optical centering: measure the actual glyph bounds (cap height differs from
// the typographic line box) and center those bounds in the tile.
let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
cg.textMatrix = .identity // string drawing above may have left a flipped matrix
let imgBounds = CTLineGetImageBounds(line, cg) // tight ink bounds in text space

// Slight optical lift so the M sits a touch above true center (reads better)
let opticalLift: CGFloat = tileSize * 0.015
let drawX = tileRect.midX - imgBounds.midX
let drawY = tileRect.midY - imgBounds.midY + opticalLift

cg.saveGState()
cg.textMatrix = .identity
cg.translateBy(x: drawX, y: drawY)
CTLineDraw(line, cg)
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()

// MARK: - Write PNG
guard let pngData = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/Users/ulfnielsen/dev/tvmv/build/icon-1024.png"
do {
    try pngData.write(to: URL(fileURLWithPath: outPath))
    print("Wrote \(outPath) (\(pngData.count) bytes)")
} catch {
    FileHandle.standardError.write("Failed to write PNG: \(error)\n".data(using: .utf8)!)
    exit(1)
}
