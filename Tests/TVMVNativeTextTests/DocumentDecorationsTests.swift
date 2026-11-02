import XCTest
import CoreGraphics
import ImageIO
import TVMVCore
@testable import TVMVNativeText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class DocumentDecorationsTests: XCTestCase {
    private let theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16, measure: 80,
                                    fullWidth: false, dark: false)
    private let delegate = MarkupLayoutDelegate()
    private let images = ImageStore()

    /// A styled text stack for `text` and the decoration input over it.
    private func input(_ text: String, inlineImageSize: CGSize? = nil, blockImagesInline: Bool = false) -> DecorationInput {
        let storage = NSTextStorage(string: text)
        let layout = MarkdownLayoutParser.parse(text)
        DocumentStyler.apply(layout, to: storage, in: NSRange(location: 0, length: storage.length), theme: theme,
                             isRevealed: { _ in false }, inlineImageSize: { _ in inlineImageSize },
                             blockImagesInline: blockImagesInline)
        let lm = NSLayoutManager()
        lm.delegate = delegate
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: CGSize(width: 360, height: CGFloat.greatestFiniteMagnitude))
        lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        return DecorationInput(
            layout: layout, theme: theme, storage: storage, layoutManager: lm, textContainer: tc,
            origin: CGPoint(x: 10, y: 10), isRevealed: { _ in false },
            isHidden: { $0 < storage.length && storage.attribute(.tvmvHidden, at: $0, effectiveRange: nil) != nil },
            images: images, blockImageSize: { _ in nil }, inlineImageSize: { _ in inlineImageSize },
            blockImagesInline: blockImagesInline, codePillRuns: [], pixelAlign: { $0 })
    }

    /// Draw `input` into a 400×100 RGBA bitmap, flipped like a flipped view,
    /// and return the RGBA bytes of the pixel at `point`.
    private func pixel(at point: CGPoint, drawing input: DecorationInput) -> [Int] {
        let bytes = bitmap(drawing: input)
        let offset = Int(point.y) * 400 * 4 + Int(point.x) * 4
        return (0..<4).map { Int(bytes[offset + $0]) }
    }

    /// Every RGBA byte of `input` drawn into a 400×100 bitmap (rows top down).
    private func bitmap(drawing input: DecorationInput) -> [UInt8] {
        let width = 400, height = 100
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        #if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        DocumentDecorations.draw(input, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        #else
        UIGraphicsPushContext(context)
        DocumentDecorations.draw(input, in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()
        #endif
        // Row 0 of the bitmap is the top: with the flip, user y maps straight to rows.
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                         count: context.bytesPerRow * height))
    }

    func testCheckedTaskDrawsAccentBox() throws {
        let input = input("- [x] done\n")
        let box = try XCTUnwrap(DocumentGeometry.taskBox(input.layout.listItems[0], input))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 400, height: 100).contains(box))
        // Upper left of the box, clear of the check mark's stroke.
        let sample = CGPoint(x: box.minX + box.width * 0.3, y: box.minY + box.height * 0.3)
        let accent = try XCTUnwrap(theme.accent.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                  intent: .defaultIntent, options: nil)?.components)
        let drawn = pixel(at: sample, drawing: input)
        for channel in 0..<3 {
            XCTAssertEqual(drawn[channel], Int((accent[channel] * 255).rounded()), accuracy: 3, "channel \(channel): \(drawn)")
        }
        XCTAssertEqual(drawn[3], 255)
    }

    func testUncheckedTaskDrawsNoFill() throws {
        let input = input("- [ ] open\n")
        let box = try XCTUnwrap(DocumentGeometry.taskBox(input.layout.listItems[0], input))
        XCTAssertEqual(pixel(at: CGPoint(x: box.midX, y: box.midY), drawing: input), [0, 0, 0, 0])
    }

    func testInlineImageDrawsOnItsCarrier() throws {
        // A solid red 20×10 PNG, loaded through the store.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tvmv-inline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (png as Data).write(to: folder.appendingPathComponent("x.png"))
        images.documentURL = folder.appendingPathComponent("doc.md")
        let loaded = expectation(description: "loaded")
        images.request(["x.png"]) { _ in loaded.fulfill() }
        wait(for: [loaded], timeout: 5)

        let input = input("A ![b](x.png) c", inlineImageSize: CGSize(width: 20, height: 10))
        let lm = input.layoutManager
        let glyph = lm.glyphIndexForCharacter(at: 2)
        let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = fragment.minX + lm.location(forGlyphAt: glyph).x + input.origin.x
        let baseline = fragment.minY + lm.location(forGlyphAt: glyph).y + input.origin.y
        XCTAssertEqual(pixel(at: CGPoint(x: x + 10, y: baseline - 5), drawing: input), [255, 0, 0, 255])
        XCTAssertEqual(pixel(at: CGPoint(x: x + 10, y: baseline + 2), drawing: input), [0, 0, 0, 0])
        XCTAssertEqual(pixel(at: CGPoint(x: x + 10, y: baseline - 12), drawing: input), [0, 0, 0, 0])
        XCTAssertEqual(pixel(at: CGPoint(x: x + 22, y: baseline - 5), drawing: input), [0, 0, 0, 0])
    }

    func testFailedBlockImageInInlineModeDrawsNoLabel() {
        images.documentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvmv-missing-\(UUID().uuidString)/doc.md")
        let failed = expectation(description: "failed")
        images.request(["missing.png"]) { _ in failed.fulfill() }
        wait(for: [failed], timeout: 5)
        XCTAssertEqual(images.state(for: "missing.png"), .failed)
        let text = "![Missing alt](missing.png)\n"
        // As a block, the failed image gets a "▨ alt" label…
        XCTAssertTrue(bitmap(drawing: input(text)).contains { $0 != 0 })
        // …styled inline (a table cell), its alt is the text: nothing is drawn.
        XCTAssertFalse(bitmap(drawing: input(text, blockImagesInline: true)).contains { $0 != 0 })
    }
}
