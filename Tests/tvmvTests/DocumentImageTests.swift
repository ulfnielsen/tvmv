import XCTest
import AppKit
import ImageIO
import TVMVCore
@testable import tvmv
@testable import TVMVNativeText

@MainActor
final class DocumentImageTests: XCTestCase {
    private var window: NSWindow!
    private var view: DocumentTextView!
    private var folder: URL!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        view = DocumentTextView.make()
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = view
        window.contentView!.addSubview(scroll)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tvmv-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("img"), withIntermediateDirectories: true)
        let folder = self.folder!
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        view.documentURL = folder.appendingPathComponent("doc.md")
    }

    /// Write a solid PNG of `width`×`height` points (1x) at `path` under the folder.
    private func writePNG(_ path: String, width: Int, height: Int) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(path))
    }

    private func pump(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func lineHeight(at index: Int) -> CGFloat {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: index), effectiveRange: nil).height
    }

    private func glyphHidden(_ index: Int) -> Bool {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        return lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: index)).contains(.null)
    }

    func testABlockImageReplacesItsSourceAtItsNaturalSize() throws {
        try writePNG("img/chart.png", width: 200, height: 100)
        let text = "Intro.\n\n![A chart](img/chart.png)\n\nAfter.\n"
        view.load(text)
        let source = (text as NSString).range(of: "![A chart](img/chart.png)")
        pump { view.imageState(for: "img/chart.png") == .loaded }
        XCTAssertEqual(view.imageState(for: "img/chart.png"), .loaded)
        XCTAssertTrue(glyphHidden(source.location))
        XCTAssertTrue(glyphHidden(NSMaxRange(source) - 1))
        XCTAssertEqual(lineHeight(at: source.location), 100 + view.theme.body.pointSize, accuracy: 1,
                       "the picture's height plus a half-em margin above and below")
    }

    func testAWideImageScalesDownToTheColumn() throws {
        try writePNG("wide.png", width: 4000, height: 400)
        let text = "![wide](wide.png)\n"
        view.load(text)
        pump { view.imageState(for: "wide.png") == .loaded }
        let column = view.textContainer!.size.width - 2 * view.textContainer!.lineFragmentPadding
        XCTAssertEqual(lineHeight(at: 0), 400 * column / 4000 + view.theme.body.pointSize, accuracy: 1)
    }

    func testRevealShowsTheSourceInsteadOfThePicture() throws {
        try writePNG("img/chart.png", width: 200, height: 100)
        let text = "![A chart](img/chart.png)\n"
        view.load(text)
        pump { view.imageState(for: "img/chart.png") == .loaded }
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.reveal(true)
        XCTAssertFalse(glyphHidden(0))
        XCTAssertEqual(lineHeight(at: 0), 1.7 * view.theme.body.pointSize, accuracy: 1)
    }

    func testAMissingImageFallsBackToAnAltTextLine() {
        let text = "![Missing chart](nope.png)\n"
        view.load(text)
        pump { view.imageState(for: "nope.png") == .failed }
        XCTAssertEqual(view.imageState(for: "nope.png"), .failed)
        XCTAssertTrue(glyphHidden(0), "the source stays hidden; the alt text is drawn instead")
        XCTAssertEqual(lineHeight(at: 0), 1.7 * view.theme.body.pointSize, accuracy: 1)
    }

    func testImageAddressesResolveLikeTheWebReader() {
        // Security review: the web reader served local images only from
        // inside the document's folder (AssetSchemeHandler.confine).
        let doc = URL(fileURLWithPath: "/docs/guide/readme.md")
        func resolve(_ s: String, _ d: URL? = doc) -> URL? { ImageSource.url(s, documentURL: d) }
        XCTAssertEqual(resolve("img/a b.png"), URL(fileURLWithPath: "/docs/guide/img/a b.png"))
        XCTAssertEqual(resolve("img/a%20b.png"), URL(fileURLWithPath: "/docs/guide/img/a b.png"))
        XCTAssertEqual(resolve("img/../a.png"), URL(fileURLWithPath: "/docs/guide/a.png"))
        XCTAssertEqual(resolve("https://e.x/p.png"), URL(string: "https://e.x/p.png"))
        XCTAssertEqual(resolve("http://e.x/p.png"), URL(string: "http://e.x/p.png"))
        XCTAssertNotNil(resolve("data:image/png;base64,iVBORw0KGgo="))
        XCTAssertNil(resolve("../shot.png"), "outside the document's folder")
        XCTAssertNil(resolve("/etc/hosts"), "absolute paths")
        XCTAssertNil(resolve("file:///tmp/p.png"), "file URLs")
        XCTAssertNil(resolve("javascript:alert(1)"))
        XCTAssertNil(resolve("img/a.png", nil), "a relative path needs a document folder")
    }

    func testASymlinkOutOfTheFolderIsNotFollowed() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("tvmv-outside-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.png"), withDestinationURL: outside)
        view.load("![x](link.png)\n")
        pump { view.imageState(for: "link.png") == .failed || view.imageState(for: "link.png") == .loaded }
        XCTAssertEqual(view.imageState(for: "link.png"), .failed)
    }

    func testDevicesAndOversizedFilesAreNotRead() throws {
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("zero.png"),
                                                   withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        try writePNG("big.png", width: 200, height: 100)
        view.maxImageBytes = 100          // smaller than big.png
        view.load("![z](zero.png)\n\n![b](big.png)\n")
        pump { view.imageState(for: "big.png") == .failed && view.imageState(for: "zero.png") == .failed }
        XCTAssertEqual(view.imageState(for: "zero.png"), .failed)
        XCTAssertEqual(view.imageState(for: "big.png"), .failed)
    }

    func testImagesOverThePixelLimitAreNotDecoded() throws {
        try writePNG("wide.png", width: 200, height: 100)
        view.maxImagePixels = 10_000      // 200×100 = 20,000
        view.load("![w](wide.png)\n")
        pump { view.imageState(for: "wide.png") == .failed || view.imageState(for: "wide.png") == .loaded }
        XCTAssertEqual(view.imageState(for: "wide.png"), .failed)
    }

    func testDownloadsStopAtTheSizeLimit() async throws {
        // URLSession streams file URLs too; the cap is the same code remote images use.
        try writePNG("big.png", width: 200, height: 100)
        let url = folder.appendingPathComponent("big.png")
        let size = try Data(contentsOf: url).count
        let whole = await ImageSource.download(url, limit: size)
        XCTAssertEqual(whole?.count, size)
        let capped = await ImageSource.download(url, limit: size - 1)
        XCTAssertNil(capped)
    }

    /// A two-frame TIFF: a small first frame and a large second one.
    private func writeTwoFrameTIFF(_ path: String) throws {
        func frame(_ side: Int) -> CGImage {
            let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
        let url = folder.appendingPathComponent(path) as CFURL
        let dest = CGImageDestinationCreateWithURL(url, "public.tiff" as CFString, 2, nil)!
        CGImageDestinationAddImage(dest, frame(10), nil)
        CGImageDestinationAddImage(dest, frame(300), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func loadAndWait(_ markdown: String, _ address: String) -> DocumentTextView.ImageState? {
        view.load(markdown)
        pump { [.loaded, .failed].contains(view.imageState(for: address)) }
        return view.imageState(for: address)
    }

    func testEveryFrameCountsTowardThePixelLimit() throws {
        // Security review: only the first frame was checked.
        try writeTwoFrameTIFF("frames.tiff")
        view.maxImagePixels = 10_000      // frame 1: 100 px, frame 2: 90,000 px
        XCTAssertEqual(loadAndWait("![f](frames.tiff)\n", "frames.tiff"), .failed)
    }

    func testVectorImagesAreHeldToTheSameLimit() throws {
        // Security review: an image ImageIO couldn't measure fell through to
        // NSImage unchecked. A small SVG (e.g. a README badge) still loads.
        let svg = { (side: Int) in
            "<svg xmlns='http://www.w3.org/2000/svg' width='\(side)' height='\(side)'><rect width='10' height='10'/></svg>"
        }
        try svg(20).write(to: folder.appendingPathComponent("badge.svg"), atomically: true, encoding: .utf8)
        try svg(5000).write(to: folder.appendingPathComponent("huge.svg"), atomically: true, encoding: .utf8)
        try "not an image at all".write(to: folder.appendingPathComponent("junk.png"), atomically: true, encoding: .utf8)
        view.maxImagePixels = 10_000
        XCTAssertEqual(loadAndWait("![b](badge.svg)\n", "badge.svg"), .loaded)
        XCTAssertEqual(loadAndWait("![h](huge.svg)\n", "huge.svg"), .failed)
        XCTAssertEqual(loadAndWait("![j](junk.png)\n", "junk.png"), .failed)
    }

    func testTransparentSVGBackgroundsShowThePage() throws {
        // An SVG without a background: only its shapes cover the page.
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100'><rect width='20' height='20' fill='black'/></svg>"
        try svg.write(to: folder.appendingPathComponent("clear.svg"), atomically: true, encoding: .utf8)
        view.load("![c](clear.svg)\n")
        pump { view.imageState(for: "clear.svg") == .loaded }
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let fragment = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let left = view.textContainerOrigin.x + view.textContainer!.lineFragmentPadding
        let top = fragment.minY + view.textContainerOrigin.y + view.theme.body.pointSize / 2
        func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor { rep.colorAt(x: Int(x * scale), y: Int(y * scale))! }
        let page = pixel(4, 4)
        let insideShape = pixel(left + 10, top + 10)
        let insideImageOutsideShape = pixel(left + 150, top + 60)
        XCTAssertLessThan(insideShape.brightnessComponent, 0.2, "the black square is drawn")
        XCTAssertEqual(insideImageOutsideShape.brightnessComponent, page.brightnessComponent, accuracy: 0.01,
                       "transparent areas show the page")
    }

    func testARevealedImageStaysRevealedWhileItsSourceIsEdited() throws {
        // Reported: editing an image link flipped between source and picture.
        // Mid-edit the line stops being an image (a ")" missing), the reveal
        // ended, and the picture came back as soon as the text was valid.
        try writePNG("img/chart.png", width: 200, height: 100)
        view.isEditable = true
        window.makeFirstResponder(view)
        view.load("![A chart](img/chart.png)\n")
        pump { view.imageState(for: "img/chart.png") == .loaded }
        view.setSelectedRange(NSRange(location: 12, length: 0))
        view.reveal(true)
        XCTAssertFalse(glyphHidden(0))
        let close = (view.string as NSString).range(of: ")")
        view.setSelectedRange(NSRange(location: NSMaxRange(close), length: 0))
        view.deleteBackward(nil)                                   // invalid: no ")"
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(glyphHidden(0), "source still shown mid-edit")
        view.insertText(")", replacementRange: view.selectedRange())   // valid again
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(view.string, "![A chart](img/chart.png)\n")
        XCTAssertFalse(glyphHidden(0), "still editing: the source stays")
        XCTAssertTrue(view.revealing)
        // Moving away ends it.
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.moveToEndOfDocument(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.cancelOperation(nil)
        XCTAssertFalse(view.revealing)
    }

    private func pasteboard(png width: Int, _ height: Int, text: String? = nil) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("tvmv-test-\(UUID().uuidString)"))
        board.clearContents()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        board.setData(rep.representation(using: .png, properties: [:]), forType: .png)
        if let text { board.setString(text, forType: .string) }
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    func testPastingAnImageSavesItBesideTheDocumentAndLinksIt() throws {
        view.isEditable = true
        view.load("Before.\n")
        view.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertTrue(view.pasteImage(from: pasteboard(png: 40, 20)))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("images").path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasPrefix("doc-") && files[0].hasSuffix(".png"), files[0])
        XCTAssertEqual(view.string, "Before.\n\n![](images/\(files[0]))\n")
        pump { view.imageState(for: "images/\(files[0])") == .loaded }
        XCTAssertEqual(view.imageState(for: "images/\(files[0])"), .loaded)

        // A second paste right away gets its own file.
        XCTAssertTrue(view.pasteImage(from: pasteboard(png: 10, 10)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("images").path).count, 2)
    }

    func testTextOnTheClipboardWinsAndReadingNeverWrites() {
        view.load("x\n")
        XCTAssertFalse(view.pasteImage(from: pasteboard(png: 10, 10)), "not editing")
        view.isEditable = true
        XCTAssertFalse(view.pasteImage(from: pasteboard(png: 10, 10, text: "words")), "text present: a text paste")
        view.documentURL = nil
        XCTAssertFalse(view.pasteImage(from: pasteboard(png: 10, 10)), "an unsaved document has no folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("images").path))
    }

    func testAnImageIsDrawnWhenOnlyAStripOfItIsRedrawn() throws {
        // Reported: images vanished while scrolling, which redraws strips.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 300, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<200 { for y in 0..<300 { rep.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("red.png"))
        for text in ["Intro.\n\n![red](red.png)\n\nAfter.\n", "![red](red.png)\n", "# *Title*\n\n![red](red.png)\n",
                     "- *a*\n\n![red](red.png)\n", "Text **bold**\n\n![red](red.png)\n\n![red](red.png)\n",
                     "```\ncode\n```\n\n![red](red.png)\n", "| a |\n|---|\n| b |\n\n![red](red.png)\n"] {
        view.load(text)
        pump { view.imageState(for: "red.png") == .loaded }
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        // Find the picture in a full redraw, then redraw strips inside it.
        let column = view.textContainerOrigin.x + view.textContainer!.lineFragmentPadding + 50
        let rows = redRows(in: view.bounds, column: column)
        XCTAssertFalse(rows.isEmpty, "image drawn in a full redraw of «\(text)»")
        guard let first = rows.first else { continue }
        // The first picture only: stop at the first gap.
        let last = zip(rows, rows.dropFirst()).first { $1 - $0 > 1 }?.0 ?? rows.last!
        for y in stride(from: first + 4, to: last - 4, by: 50) {
            let strip = NSRect(x: 0, y: y, width: view.bounds.width, height: 8)
            let red = redRows(in: strip, column: column).count
            XCTAssertGreaterThan(red, 0, "image drawn in a strip at \(y) in «\(text)»")
        }
        }
    }

    /// The view-y of each row whose pixel at `column` is red, when only `rect` is redrawn.
    private func redRows(in rect: NSRect, column: CGFloat) -> [CGFloat] {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: rect)!
        view.cacheDisplay(in: rect, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / rect.height
        return (0..<bitmap.pixelsHigh).compactMap { y in
            guard let c = bitmap.colorAt(x: Int((column - rect.minX) * scale), y: y)?.usingColorSpace(.deviceRGB),
                  c.redComponent > 0.8, c.greenComponent < 0.3 else { return nil }
            return rect.minY + CGFloat(y) / scale
        }
    }

    // MARK: Inline images

    /// The view-x where the character at `index` starts.
    private func x(at index: Int) -> CGFloat {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        let glyph = lm.glyphIndexForCharacter(at: index)
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + lm.location(forGlyphAt: glyph).x
    }

    private var column: CGFloat { view.textContainer!.size.width - 2 * view.textContainer!.lineFragmentPadding }

    private func inlineImage() -> MarkdownLayout.InlineImage { view.layout.inlineImages[0] }

    func testInlineImageShowsAsPicture() throws {
        try writePNG("img/dot.png", width: 16, height: 16)
        view.load("A ![b](img/dot.png) c\n")
        pump { view.imageState(for: "img/dot.png") == .loaded }
        XCTAssertEqual(view.imageState(for: "img/dot.png"), .loaded)
        let image = inlineImage()
        XCTAssertFalse(glyphHidden(image.range.location), "the carrier keeps the picture's room")
        for i in image.range.location + 1..<NSMaxRange(image.range) { XCTAssertTrue(glyphHidden(i), "\(i)") }
        XCTAssertEqual(x(at: NSMaxRange(image.range)) - x(at: image.range.location), 16, accuracy: 0.5)
    }

    func testUnloadedInlineImageShowsAlt() {
        view.load("A ![b](img/missing.png) c\n")
        pump { view.imageState(for: "img/missing.png") == .failed }
        XCTAssertEqual(view.imageState(for: "img/missing.png"), .failed)
        XCTAssertFalse(glyphHidden(4), "the alt shows")
        XCTAssertTrue(glyphHidden(2))
    }

    func testCaretPassesInlineImageInOneStep() throws {
        try writePNG("img/dot.png", width: 16, height: 16)
        view.isEditable = true
        window.makeFirstResponder(view)
        view.load("A ![b](img/dot.png) c\n")
        pump { view.imageState(for: "img/dot.png") == .loaded }
        let image = inlineImage()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.moveRight(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: NSMaxRange(image.range), length: 0))
        view.moveLeft(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testBackspaceDeletesWholeInlineImage() throws {
        try writePNG("img/dot.png", width: 16, height: 16)
        view.isEditable = true
        window.makeFirstResponder(view)
        let text = "A ![b](img/dot.png) c\n"
        view.load(text)
        pump { view.imageState(for: "img/dot.png") == .loaded }
        view.setSelectedRange(NSRange(location: NSMaxRange(inlineImage().range), length: 0))
        view.deleteBackward(nil)
        pump { view.string != text }
        XCTAssertEqual(view.string, "A  c\n")
        view.undoManager!.undo()
        XCTAssertEqual(view.string, text)
    }

    func testDeleteForwardDeletesWholeInlineImage() throws {
        try writePNG("img/dot.png", width: 16, height: 16)
        view.isEditable = true
        window.makeFirstResponder(view)
        let text = "A ![b](img/dot.png) c\n"
        view.load(text)
        pump { view.imageState(for: "img/dot.png") == .loaded }
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.deleteForward(nil)
        pump { view.string != text }
        XCTAssertEqual(view.string, "A  c\n")
    }

    func testClickOnLinkedImageFollowsLink() throws {
        try writePNG("img/dot.png", width: 16, height: 16)
        view.load("[![b](img/dot.png)](https://x.example)\n")
        pump { view.imageState(for: "img/dot.png") == .loaded }
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        let carrier = inlineImage().range.location
        let fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: carrier), effectiveRange: nil)
        let centre = NSPoint(x: x(at: carrier) + 8 + view.textContainerOrigin.x,
                             y: fragment.midY + view.textContainerOrigin.y)
        XCTAssertEqual(view.link(at: centre), "https://x.example")
    }

    func testEditedAddressLoadsNewImage() throws {
        try writePNG("img/dot.png", width: 16, height: 16)
        try writePNG("img/dot2.png", width: 32, height: 16)
        view.isEditable = true
        window.makeFirstResponder(view)
        view.load("A ![b](img/dot.png) c\n")
        pump { view.imageState(for: "img/dot.png") == .loaded }
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.toggleRevealMarkup(nil)
        let name = (view.string as NSString).range(of: "dot.png")
        view.insertText("dot2.png", replacementRange: name)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.moveToEndOfDocument(nil)
        pump { view.imageState(for: "img/dot2.png") == .loaded && !view.revealing }
        view.cancelOperation(nil)
        XCTAssertEqual(view.imageState(for: "img/dot2.png"), .loaded)
        let image = inlineImage()
        XCTAssertEqual(image.url, "img/dot2.png")
        let width = InlineImageMetrics.size(natural: CGSize(width: 32, height: 16), theme: view.theme, column: column).width
        XCTAssertEqual(x(at: NSMaxRange(image.range)) - x(at: image.range.location), width, accuracy: 0.5)
    }

    func testFontSizeChangeResizesInlineImage() throws {
        try writePNG("img/tall.png", width: 40, height: 80)
        view.load("A ![b](img/tall.png) c\n")
        pump { view.imageState(for: "img/tall.png") == .loaded }
        view.theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 24, measure: 70, fullWidth: false, dark: false)
        let image = inlineImage()
        let width = InlineImageMetrics.size(natural: CGSize(width: 40, height: 80), theme: view.theme, column: column).width
        XCTAssertEqual(width, 40 * 24 * 1.4 / 80, accuracy: 0.01, "capped at 1.4 em")
        XCTAssertEqual(x(at: NSMaxRange(image.range)) - x(at: image.range.location), width, accuracy: 0.5)
    }

    func testTableCellShowsImageAsPicture() throws {
        try writePNG("img/dot.png", width: 16, height: 16)
        view.load("| a |\n|---|\n| ![b](img/dot.png) |\n")
        let cell = try XCTUnwrap(view.tableGrids.first?.cells.last?.first)
        XCTAssertTrue(cell.engine.treatsBlockImagesAsInline)
        pump { cell.imageState(for: "img/dot.png") == .loaded }
        XCTAssertEqual(cell.imageState(for: "img/dot.png"), .loaded)
        XCTAssertEqual(cell.textStorage!.attribute(.tvmvImageCarrier, at: 0, effectiveRange: nil) as? String, "img/dot.png")
    }

    // MARK: Inline images: caret, delete and copy at their edges

    /// Load `text` editable with `img/a.png` and `img/b.png` (16×16), wait for both.
    private func loadEditable(_ text: String, in target: DocumentTextView? = nil) throws {
        try writePNG("img/a.png", width: 16, height: 16)
        try writePNG("img/b.png", width: 16, height: 16)
        view.isEditable = true
        window.makeFirstResponder(view)
        view.load(text)
        pump { view.imageState(for: "img/a.png") == .loaded && (view.imageState(for: "img/b.png") ?? .loaded) == .loaded }
    }

    private func images(_ v: DocumentTextView? = nil) -> [NSRange] { (v ?? view).layout.inlineImages.map(\.range) }

    func testCaretRestsBeforeAnImageThatStartsALine() throws {
        try loadEditable("![a](img/a.png) text\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(view.selectedRange().location, 0)
        view.moveToEndOfLine(nil)
        view.moveToBeginningOfLine(nil)
        XCTAssertEqual(view.selectedRange().location, 0)
        view.insertText("x", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, "x![a](img/a.png) text\n")
    }

    func testCaretStopsBetweenAdjacentImages() throws {
        for text in ["A ![a](img/a.png)![b](img/b.png) c\n",
                     "A [![a](img/a.png)](https://u.example)[![b](img/b.png)](https://v.example) c\n"] {
            try loadEditable(text)
            let (a, b) = (images()[0], images()[1])
            // One picture per press, with a stop between the two.
            view.setSelectedRange(NSRange(location: a.location, length: 0))
            view.moveRight(nil)
            XCTAssertEqual(view.selectedRange().location, NSMaxRange(a), "after a in «\(text)»")
            view.moveRight(nil)
            XCTAssertEqual(view.selectedRange().location, NSMaxRange(b), "after b in «\(text)»")
            view.moveLeft(nil)
            XCTAssertEqual(view.selectedRange().location, b.location, "before b in «\(text)»")
            view.moveLeft(nil)
            XCTAssertEqual(view.selectedRange().location, a.location, "before a in «\(text)»")
            // A caret put between them stays: typing lands there.
            view.setSelectedRange(NSRange(location: b.location, length: 0))
            XCTAssertEqual(view.selectedRange().location, b.location)
            view.setSelectedRange(NSRange(location: NSMaxRange(a), length: 0))
            XCTAssertEqual(view.selectedRange().location, NSMaxRange(a))
        }
    }

    func testBackspaceAfterALinkedImageDeletesTheLink() throws {
        let text = "ab [![b](img/a.png)](https://x.example) cd\n"
        try loadEditable(text)
        let end = (text as NSString).range(of: "example)").location + 8
        view.setSelectedRange(NSRange(location: end, length: 0))
        view.deleteBackward(nil)
        pump { view.string != text }
        XCTAssertEqual(view.string, "ab  cd\n")
        view.undoManager!.undo()
        XCTAssertEqual(view.string, text)
        // Forward: Delete before the link.
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.deleteForward(nil)
        pump { view.string != text }
        XCTAssertEqual(view.string, "ab  cd\n")
    }

    func testBackspaceAcrossHiddenMarkupDeletesTheImage() throws {
        let text = "ab ![b](img/a.png)**cd** e\n"
        try loadEditable(text)
        let cd = (text as NSString).range(of: "cd").location
        view.setSelectedRange(NSRange(location: cd, length: 0))
        view.deleteBackward(nil)
        pump { view.string != text }
        XCTAssertEqual(view.string, "ab **cd** e\n")
        view.undoManager!.undo()
        XCTAssertEqual(view.string, text)
        // Forward: Delete after "ab " over hidden markup that ends at the image.
        let text2 = "ab **cd**![b](img/a.png) e\n"
        view.load(text2)
        pump { view.layout.inlineImages.count == 1 && view.textStorage!.attribute(.tvmvImageCarrier, at: 9, effectiveRange: nil) != nil }
        view.setSelectedRange(NSRange(location: 7, length: 0))   // after "cd"
        view.deleteForward(nil)
        pump { view.string != text2 }
        XCTAssertEqual(view.string, "ab **cd** e\n")
    }

    func testCopyBesideAnImageLeavesItOut() throws {
        let text = "A ![b](img/a.png) c\n"
        try loadEditable(text)
        let image = images()[0]
        let s = text as NSString
        XCTAssertEqual(s.substring(with: view.copyRange(for: NSRange(location: 0, length: 2))), "A ")
        XCTAssertEqual(s.substring(with: view.copyRange(for: NSRange(location: NSMaxRange(image), length: 2))), " c")
        XCTAssertEqual(s.substring(with: view.copyRange(for: NSRange(location: image.location, length: 1))), "![b](img/a.png)")
        XCTAssertEqual(s.substring(with: view.copyRange(for: NSRange(location: 0, length: 3))), "A ![b](img/a.png)")
        view.setSelectedRange(NSRange(location: 0, length: 2))
        view.cut(nil)
        XCTAssertEqual(view.string, "![b](img/a.png) c\n")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "A ")
        view.undoManager!.undo()
        view.setSelectedRange(NSRange(location: image.location, length: 1))
        view.cut(nil)
        XCTAssertEqual(view.string, "A  c\n")
    }

    func testRightArrowPassesAnUnloadedImagesHiddenMarkup() {
        // Reported: with the image failed (or loading) its "![" is hidden, and
        // right-arrow from before it put the caret at the document's start.
        view.isEditable = true
        window.makeFirstResponder(view)
        view.load("A ![b](img/missing.png) c\n")
        pump { view.imageState(for: "img/missing.png") == .failed }
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.moveRight(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 0), "past the hidden ![ and the alt")
        view.moveRight(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 24, length: 0), "past the hidden tail and the space")
        view.setSelectedRange(NSRange(location: 23, length: 0))
        view.moveLeft(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0), "back past the tail and the alt")
    }

    // MARK: Images settling, and images in table cells

    func testImagesSettlingTogetherLayOutTheGridsOnce() {
        // Addresses outside the folder fail at once, all in one turn. Each
        // used to restyle and re-lay every grid: a page of tables with
        // images took 34 s to settle.
        var text = ""
        for i in 0..<20 { text += "Para \(i) ![a](../out\(i).png) text.\n\n" }
        for _ in 0..<3 { text += "| a | b |\n|---|---|\n| x | y |\n\n" }
        let (passes, updates) = (view.gridLayoutPasses, view.gridUpdates)
        view.load(text)
        pump { (0..<20).allSatisfy { view.imageState(for: "../out\($0).png") == .failed } }
        XCTAssertEqual(view.imageState(for: "../out19.png"), .failed)
        XCTAssertEqual(view.gridLayoutPasses - passes, 2, "the load's pass, and one for the images that settled in one turn")
        XCTAssertEqual(view.gridUpdates - updates, 3, "each grid measured at the load; none holds an image")
        XCTAssertFalse(glyphHidden((text as NSString).range(of: "![a](../out19").location + 2), "the failed image shows its alt")
    }

    func testACellsImageLoadingReMeasuresItsGrid() throws {
        // The grid exists before the image loads; once it does, the grid is
        // re-measured: the picture wraps the cell's text to a second line,
        // and the grid is laid out as a fresh one would be.
        try writePNG("img/wide.png", width: 120, height: 20)
        view.setFrameSize(NSSize(width: 420, height: view.frame.height))   // a narrow window
        let text = "Text.\n\n| word word ![b](img/wide.png) | c |\n|---|---|\n| x | y |\n"
        view.load(text)
        let grid = try XCTUnwrap(view.tableGrids.first)
        let cell = grid.cell(row: 0, column: 0)
        let before = cell.frame
        let updates = view.gridUpdates
        pump { view.imageState(for: "img/wide.png") == .loaded }
        let bang = (cell.string as NSString).range(of: "![b]").location
        XCTAssertEqual(cell.textStorage!.attribute(.tvmvImageCarrier, at: bang, effectiveRange: nil) as? String, "img/wide.png")
        XCTAssertGreaterThan(cell.frame.height, before.height + 10, "the picture wraps the cell's text")
        XCTAssertEqual(view.gridUpdates - updates, 1, "only its grid is re-measured")
        let measured = grid.cells.map { $0.map(\.frame) }
        let gridFrame = grid.frame
        // Rebuilt from scratch (a new theme with the same metrics), the grid
        // measures the same columns and rows.
        let theme = view.theme
        view.theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16, measure: 80, fullWidth: false, dark: true)
        view.theme = theme
        XCTAssertEqual(grid.cells.map { $0.map(\.frame) }, measured)
        XCTAssertEqual(grid.frame, gridFrame)
    }

    func testCellsShareTheDocumentsImages() throws {
        try writePNG("img/a.png", width: 16, height: 16)
        try writePNG("img/b.png", width: 16, height: 16)
        view.load("A ![p](img/a.png) b\n\n| ![p](img/a.png) | ![p](img/a.png) |\n|---|---|\n| ![q](img/b.png) | x |\n")
        pump { view.imageState(for: "img/a.png") == .loaded && view.imageState(for: "img/b.png") == .loaded }
        let grid = try XCTUnwrap(view.tableGrids.first)
        // A new theme rebuilds the grid's cells.
        view.theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 18, measure: 80, fullWidth: false, dark: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(view.imageLoadsStarted, 2, "one load per address, across the document and its cells")
        let cell = grid.cell(row: 1, column: 0)
        XCTAssertTrue(grid.cells.joined().allSatisfy { $0.imageStore === view.imageStore })
        XCTAssertEqual(cell.textStorage!.attribute(.tvmvImageCarrier, at: 0, effectiveRange: nil) as? String, "img/b.png")
        XCTAssertEqual(cell.imageState(for: "img/b.png"), .loaded)
        // A cell resolves addresses against the document's current file.
        let moved = folder.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: moved.appendingPathComponent("img"), withIntermediateDirectories: true)
        try writePNG("moved/img/c.png", width: 16, height: 16)
        view.documentURL = moved.appendingPathComponent("doc.md")
        view.load("| ![r](img/c.png) |\n|---|\n| x |\n")
        pump { view.imageState(for: "img/c.png") == .loaded }
        XCTAssertEqual(view.imageState(for: "img/c.png"), .loaded)
        XCTAssertEqual(view.tableGrids[0].cell(row: 0, column: 0).textStorage!
            .attribute(.tvmvImageCarrier, at: 0, effectiveRange: nil) as? String, "img/c.png")
    }

    func testCaretCrossesAnImageInATableCell() throws {
        try writePNG("img/a.png", width: 16, height: 16)
        view.isEditable = true
        view.load("| a |\n|---|\n| x ![a](img/a.png) y |\n")
        let cell = try XCTUnwrap(view.tableGrids.first?.cells.last?.first)
        pump { cell.textStorage!.length > 0 && cell.textStorage!.attribute(.tvmvImageCarrier, at: 2, effectiveRange: nil) != nil }
        window.makeFirstResponder(cell)
        let image = images(cell)[0]
        cell.setSelectedRange(NSRange(location: image.location, length: 0))
        XCTAssertEqual(cell.selectedRange().location, image.location)
        cell.moveRight(nil)
        XCTAssertEqual(cell.selectedRange().location, NSMaxRange(image))
        cell.moveLeft(nil)
        XCTAssertEqual(cell.selectedRange().location, image.location)
    }

    func testCaretRestsBeforeAnImageAloneInACell() throws {
        try writePNG("img/a.png", width: 16, height: 16)
        view.isEditable = true
        view.load("| a |\n|---|\n| ![a](img/a.png) |\n")
        let cell = try XCTUnwrap(view.tableGrids.first?.cells.last?.first)
        pump { cell.textStorage!.length > 0 && cell.textStorage!.attribute(.tvmvImageCarrier, at: 0, effectiveRange: nil) != nil }
        window.makeFirstResponder(cell)
        cell.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(cell.selectedRange().location, 0)
        cell.moveToEndOfLine(nil)
        XCTAssertEqual(cell.selectedRange().location, cell.textStorage!.length)
        cell.moveLeft(nil)
        XCTAssertEqual(cell.selectedRange().location, 0)
    }

    func testABulletBeforeAnImageAnchorsAtThePicture() throws {
        try writePNG("img/a.png", width: 16, height: 16)
        view.load("- ![a](img/a.png) text\n")
        pump { view.imageState(for: "img/a.png") == .loaded }
        let anchor = try XCTUnwrap(view.bulletAnchor(for: view.layout.listItems[0]))
        XCTAssertEqual(anchor.x, x(at: 2) + view.textContainerOrigin.x, accuracy: 0.5, "the text starts at the picture")
    }

    func testAPictureLandsOnWholeDevicePixels() throws {
        // Reported: SVGs sharp at some window widths, fuzzy at others. The
        // lines above set where a picture starts; at a fractional point its
        // edges smeared across two pixel rows.
        var grid = ""
        for i in stride(from: 0, through: 180, by: 20) {
            grid += "<rect x=\"\(i)\" y=\"0\" width=\"2\" height=\"200\"/><rect x=\"0\" y=\"\(i)\" width=\"200\" height=\"2\"/>"
        }
        try "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"200\" viewBox=\"0 0 200 200\">\(grid)</svg>"
            .write(to: folder.appendingPathComponent("grid.svg"), atomically: true, encoding: .utf8)
        for text in ["![g](grid.svg)\n", "Para one.\n\nPara two **b**.\n\n![g](grid.svg)\n", "# Title\n\nText.\n\n![g](grid.svg)\n"] {
            view.load(text)
            pump { view.imageState(for: "grid.svg") == .loaded }
            let lm = view.layoutManager!
            lm.ensureLayout(for: view.textContainer!)
            let source = (view.string as NSString).range(of: "![g]")
            let fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: source.location), effectiveRange: nil)
            // The picture, inset so its antialiased outer border stays out.
            // On whole points, as the window draws it.
            let area = NSIntegralRect(NSRect(x: view.textContainerOrigin.x + view.textContainer!.lineFragmentPadding + 4,
                                             y: fragment.minY + view.textContainerOrigin.y + view.theme.body.pointSize / 2 + 4,
                                             width: 190, height: 190))
            let bitmap = view.bitmapImageRepForCachingDisplay(in: area)!
            view.cacheDisplay(in: area, to: bitmap)
            var grey = 0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let v = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                if v > 0.1, v < 0.85 { grey += 1 }
            } }
            XCTAssertEqual(grey, 0, "grid edges crisp after «\(text)» (line at y \(fragment.minY))")
        }
    }
}
