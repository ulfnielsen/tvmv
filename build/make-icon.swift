import AppKit
import Foundation

// CONCEPT 2 — "Serif M on paper"
// Offscreen 1024x1024 RGBA icon: elegant serif capital "M" in dark ink
// on a warm cream-to-parchment gradient tile, with subtle paper character.

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

// MARK: - Faint horizontal baseline rule
let ruleColor = NSColor(calibratedRed: 0.42, green: 0.33, blue: 0.20, alpha: 0.14)
ruleColor.setStroke()
let ruleY = tileRect.minY + tileSize * 0.265
let rule = NSBezierPath()
rule.lineWidth = 3
let ruleInset = tileSize * 0.16
rule.move(to: NSPoint(x: tileRect.minX + ruleInset, y: ruleY))
rule.line(to: NSPoint(x: tileRect.maxX - ruleInset, y: ruleY))
rule.stroke()

cg.restoreGState()

// MARK: - Serif capital "M" glyph
func resolveFont(size: CGFloat) -> NSFont {
    let candidates = ["Source Serif 4 Semibold", "SourceSerif4-Semibold",
                      "Source Serif 4", "Georgia-Bold", "Georgia"]
    for name in candidates {
        if let f = NSFont(name: name, size: size) {
            return f
        }
    }
    // System serif fallback
    if #available(macOS 10.15, *) {
        return NSFont(descriptor:
            NSFont.systemFont(ofSize: size, weight: .semibold)
                .fontDescriptor.withDesign(.serif) ?? NSFont.systemFont(ofSize: size).fontDescriptor,
            size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }
    return NSFont.boldSystemFont(ofSize: size)
}

let glyphFontSize = tileSize * 0.62
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

let outPath = "/Users/ulfnielsen/dev/tvmv/build/icon-candidates/cand-2.png"
do {
    try pngData.write(to: URL(fileURLWithPath: outPath))
    print("Wrote \(outPath) (\(pngData.count) bytes)")
} catch {
    FileHandle.standardError.write("Failed to write PNG: \(error)\n".data(using: .utf8)!)
    exit(1)
}
