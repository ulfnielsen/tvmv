import XCTest
import AppKit
import ImageIO
import TVMVCore
@testable import tvmv

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
        func resolve(_ s: String, _ d: URL? = doc) -> URL? { DocumentTextView.imageURL(s, documentURL: d) }
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
        let whole = await DocumentTextView.download(url, limit: size)
        XCTAssertEqual(whole?.count, size)
        let capped = await DocumentTextView.download(url, limit: size - 1)
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
}
