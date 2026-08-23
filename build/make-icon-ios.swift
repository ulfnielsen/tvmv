import AppKit
import Foundation

// tvmv iOS icon — same "Serif M on paper, over greeked text" design as
// make-icon.swift, but FULL-BLEED and OPAQUE: iOS masks its own icon shape,
// so the macOS tile's rounded corners, transparent margins, and drop shadow
// must not be baked in (they'd render as black edges under the mask), and the
// App Store's 1024 marketing icon rejects PNGs with an alpha channel.

let canvas: CGFloat = 1024

// MARK: - Offscreen bitmap (RGB, no alpha channel)
// NSGraphicsContext(bitmapImageRep:) rejects 3-sample reps; draw into a
// CGContext with skipped alpha instead, so the encoded PNG carries no
// alpha channel at all.
guard let cgBitmap = CGContext(
    data: nil,
    width: Int(canvas), height: Int(canvas),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    FileHandle.standardError.write("Failed to create CGContext\n".data(using: .utf8)!)
    exit(1)
}
let ctx = NSGraphicsContext(cgContext: cgBitmap, flipped: false)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

let tileRect = NSRect(x: 0, y: 0, width: canvas, height: canvas)
let tileSize = canvas

// MARK: - Warm cream-to-parchment gradient fill (edge to edge)
let cream = NSColor(calibratedRed: 0.992, green: 0.972, blue: 0.929, alpha: 1.0)
let parchment = NSColor(calibratedRed: 0.945, green: 0.901, blue: 0.819, alpha: 1.0)
NSGradient(colors: [cream, parchment])!.draw(in: tileRect, angle: -90)

// MARK: - Soft inner vignette (paper character)
let center = NSPoint(x: tileRect.midX, y: tileRect.midY)
NSGradient(colors: [
    NSColor.clear,
    NSColor(calibratedRed: 0.62, green: 0.54, blue: 0.40, alpha: 0.0),
    NSColor(calibratedRed: 0.50, green: 0.41, blue: 0.27, alpha: 0.16)
])!.draw(fromCenter: center, radius: tileSize * 0.18,
         toCenter: center, radius: tileSize * 0.74,
         options: [])

// MARK: - Serif font resolver (matches make-icon.swift)
func resolveFont(size: CGFloat) -> NSFont {
    let candidates = ["Source Serif 4 Semibold", "SourceSerif4-Semibold",
                      "Source Serif 4", "Georgia-Bold", "Georgia"]
    for name in candidates {
        if let f = NSFont(name: name, size: size) { return f }
    }
    return NSFont.boldSystemFont(ofSize: size)
}

// MARK: - Faint lorem ipsum page behind the M
// Insets are generous enough that iOS's corner mask never clips a line.
let textInsetX = tileSize * 0.14
let textInsetY = tileSize * 0.11
let textRect = NSRect(
    x: textInsetX, y: textInsetY,
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
        .font: resolveFont(size: tileSize * 0.050),
        .foregroundColor: headingInkColor,
        .paragraphStyle: bodyStyle,
    ]))
page.append(NSAttributedString(
    string: lorem,
    attributes: [
        .font: resolveFont(size: tileSize * 0.036),
        .foregroundColor: bodyInk,
        .paragraphStyle: bodyStyle,
    ]))
page.draw(with: textRect, options: [.usesLineFragmentOrigin])

// MARK: - Serif capital "M" glyph, optically centered
// 0.60 of the full canvas ≈ the same visual weight the Mac icon's M has
// within its 824pt tile.
let glyphFontSize = tileSize * 0.60
let inkColor = NSColor(calibratedRed: 0.149, green: 0.118, blue: 0.090, alpha: 1.0)
let attr = NSAttributedString(string: "M", attributes: [
    .font: resolveFont(size: glyphFontSize),
    .foregroundColor: inkColor,
    .kern: 0.0
])

let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
cg.textMatrix = .identity
let imgBounds = CTLineGetImageBounds(line, cg)

let opticalLift: CGFloat = tileSize * 0.015
cg.saveGState()
cg.textMatrix = .identity
cg.translateBy(x: tileRect.midX - imgBounds.midX,
               y: tileRect.midY - imgBounds.midY + opticalLift)
CTLineDraw(line, cg)
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()

// MARK: - Write PNG
guard let cgImage = cgBitmap.makeImage(),
      let pngData = NSBitmapImageRep(cgImage: cgImage)
        .representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "ios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
do {
    try pngData.write(to: URL(fileURLWithPath: outPath))
    print("Wrote \(outPath) (\(pngData.count) bytes)")
} catch {
    FileHandle.standardError.write("Failed to write PNG: \(error)\n".data(using: .utf8)!)
    exit(1)
}
