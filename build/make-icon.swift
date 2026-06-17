import AppKit

// ---- Canvas setup ----
let size = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("rep") }

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("ctx") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

// Transparent background (leave clear outside tile)

// ---- Tile geometry ----
let inset: CGFloat = 100
let tileRect = NSRect(x: inset, y: inset,
                      width: CGFloat(size) - inset * 2,
                      height: CGFloat(size) - inset * 2)
let cornerRadius: CGFloat = tileRect.width * 0.2237

// ---- Drop shadow (drawn under the tile) ----
cg.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -10) // visually downward in this coordinate space
shadow.set()

// Opaque path to cast a clean shadow
let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: cornerRadius, yRadius: cornerRadius)
NSColor.black.setFill()
tilePath.fill()
cg.restoreGState()

// ---- Gradient fill: deep indigo -> violet (vertical) ----
cg.saveGState()
tilePath.addClip()
let topColor    = NSColor(srgbRed: 0.20, green: 0.10, blue: 0.45, alpha: 1.0) // violet (top)
let bottomColor = NSColor(srgbRed: 0.13, green: 0.07, blue: 0.34, alpha: 1.0) // deep indigo (bottom)
// Vertical gradient: top brighter violet to deep indigo bottom
let gradient = NSGradient(starting: bottomColor, ending: topColor)!
gradient.draw(in: tileRect, angle: 90) // 90deg = upward, so ending(top) at top
// Subtle top-edge highlight for depth
let hl = NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0.0)])!
hl.draw(in: tileRect, angle: 90)
cg.restoreGState()

// ---- The Markdown mark ----
// Classic CommonMark mark: a rounded-rect OUTLINE badge containing
// a capital "M" and a downward-pointing arrowhead to its right.
// Target: mark occupies ~55% of tile width, perfectly centered.

let markWidth = tileRect.width * 0.55
// Standard markdown mark aspect ratio ~ 208:128 (width:height) -> ~1.625
let markHeight = markWidth * (128.0 / 208.0)
let markRect = NSRect(
    x: tileRect.midX - markWidth / 2,
    y: tileRect.midY - markHeight / 2,
    width: markWidth, height: markHeight
)

let white = NSColor(srgbRed: 0.98, green: 0.97, blue: 1.0, alpha: 1.0)

// --- Outline badge ---
let badgeStroke = markWidth * 0.058
let badgeRadius = markHeight * 0.16
let badgeInset = badgeStroke / 2
let badgePath = NSBezierPath(
    roundedRect: markRect.insetBy(dx: badgeInset, dy: badgeInset),
    xRadius: badgeRadius, yRadius: badgeRadius
)
badgePath.lineWidth = badgeStroke
white.setStroke()
badgePath.stroke()

// Inner content padding
let padX = markWidth * 0.14
let padY = markHeight * 0.20
let inner = markRect.insetBy(dx: padX, dy: padY)

// Layout: left ~58% for the "M", right ~38% for the arrow, small gap
let gap = inner.width * 0.06
let mWidth = inner.width * 0.56
let arrowWidth = inner.width - mWidth - gap

// --- Capital "M" drawn as a thick filled glyph (4 strokes / zigzag) ---
let mStroke = mWidth * 0.235
let mRect = NSRect(x: inner.minX, y: inner.minY, width: mWidth, height: inner.height)

// Build the M as a filled polygon (outer zigzag down to inner) for crispness.
let mPath = NSBezierPath()
let xL = mRect.minX
let xR = mRect.maxX
let yB = mRect.minY
let yT = mRect.maxY
let s = mStroke
let midX = mRect.midX
// V notch depth (how far down the center dips from top)
let notch = mRect.height * 0.42

// Outer outline of the M, traced clockwise from bottom-left
mPath.move(to: NSPoint(x: xL, y: yB))                          // bottom-left outer
mPath.line(to: NSPoint(x: xL, y: yT))                          // up left outer
mPath.line(to: NSPoint(x: xL + s, y: yT))                      // top of left leg (inner top)
mPath.line(to: NSPoint(x: midX, y: yT - notch + s * 0.55))     // down to center valley (inner)
mPath.line(to: NSPoint(x: xR - s, y: yT))                      // up to top of right leg
mPath.line(to: NSPoint(x: xR, y: yT))                          // top-right outer
mPath.line(to: NSPoint(x: xR, y: yB))                          // down right outer
mPath.line(to: NSPoint(x: xR - s, y: yB))                      // bottom of right leg inner
mPath.line(to: NSPoint(x: xR - s, y: yT - notch * 0.50))       // up right inner toward valley
mPath.line(to: NSPoint(x: midX, y: yB + notch * 0.34))         // down to inner valley bottom
mPath.line(to: NSPoint(x: xL + s, y: yT - notch * 0.50))       // up left inner from valley
mPath.line(to: NSPoint(x: xL + s, y: yB))                      // down to bottom of left leg inner
mPath.close()
mPath.windingRule = .nonZero
white.setFill()
mPath.fill()

// --- Downward-pointing arrow: vertical stem + arrowhead ---
let aCenterX = inner.maxX - arrowWidth / 2
let stemWidth = arrowWidth * 0.30
let headWidth = arrowWidth          // full width arrowhead
// Stem occupies top portion, head bottom portion
let headHeight = inner.height * 0.42
let stemTop = inner.maxY
let stemBottom = inner.minY + headHeight - inner.height * 0.02
let arrowTipY = inner.minY

let arrowPath = NSBezierPath()
// Stem (rectangle)
let stemRect = NSRect(
    x: aCenterX - stemWidth / 2,
    y: stemBottom,
    width: stemWidth,
    height: stemTop - stemBottom
)
arrowPath.appendRect(stemRect)
white.setFill()
arrowPath.fill()

// Arrowhead (triangle pointing down)
let head = NSBezierPath()
head.move(to: NSPoint(x: aCenterX - headWidth / 2, y: stemBottom + headHeight * 0.10))
head.line(to: NSPoint(x: aCenterX + headWidth / 2, y: stemBottom + headHeight * 0.10))
head.line(to: NSPoint(x: aCenterX, y: arrowTipY))
head.close()
head.fill()

// ---- Finalize ----
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
let outURL = URL(fileURLWithPath: "/Users/ulfnielsen/dev/tvmv/build/icon-candidates/cand-1.png")
try! data.write(to: outURL)
print("wrote \(outURL.path)")
