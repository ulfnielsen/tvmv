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
        let doc = URL(fileURLWithPath: "/docs/guide/readme.md")
        func resolve(_ s: String, _ d: URL? = doc) -> URL? { DocumentTextView.imageURL(s, documentURL: d) }
        XCTAssertEqual(resolve("img/a b.png"), URL(fileURLWithPath: "/docs/guide/img/a b.png"))
        XCTAssertEqual(resolve("img/a%20b.png"), URL(fileURLWithPath: "/docs/guide/img/a b.png"))
        XCTAssertEqual(resolve("../shot.png"), URL(fileURLWithPath: "/docs/shot.png"))
        XCTAssertEqual(resolve("https://e.x/p.png"), URL(string: "https://e.x/p.png"))
        XCTAssertEqual(resolve("http://e.x/p.png"), URL(string: "http://e.x/p.png"))
        XCTAssertEqual(resolve("file:///tmp/p.png"), URL(string: "file:///tmp/p.png"))
        XCTAssertNotNil(resolve("data:image/png;base64,iVBORw0KGgo="))
        XCTAssertNil(resolve("javascript:alert(1)"))
        XCTAssertNil(resolve("img/a.png", nil), "a relative path needs a document folder")
    }
}
