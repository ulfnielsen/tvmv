import XCTest
import AppKit
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
}
