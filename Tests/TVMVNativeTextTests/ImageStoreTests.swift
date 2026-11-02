import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import TVMVNativeText

@MainActor
final class ImageStoreTests: XCTestCase {
    private func pngData(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func pump(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testAddressesOutsideTheFolderAreRefused() {
        let doc = URL(fileURLWithPath: "/tmp/d/doc.md")
        XCTAssertNil(ImageSource.url("../x.png", documentURL: doc))
        XCTAssertNil(ImageSource.url("/etc/x.png", documentURL: doc))
        XCTAssertNil(ImageSource.url("file:///x.png", documentURL: doc))
        XCTAssertEqual(ImageSource.url("img/x.png", documentURL: doc)?.path, "/tmp/d/img/x.png")
        XCTAssertEqual(ImageSource.url("https://e.com/x.png", documentURL: doc)?.absoluteString, "https://e.com/x.png")
    }

    func testDecoderRefusesOverPixelCap() {
        let data = pngData(width: 200, height: 100)
        XCTAssertNotNil(ImageDecoder.decode(data, maxPixels: 20_000))
        XCTAssertNil(ImageDecoder.decode(data, maxPixels: 19_999))
    }

    func testStoreLoadsOnceAndReports() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tvmv-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try pngData(width: 20, height: 10).write(to: folder.appendingPathComponent("a.png"))

        let store = ImageStore()
        store.documentURL = folder.appendingPathComponent("doc.md")
        var loaded: [String] = []
        store.request(["a.png", "a.png", "missing.png"]) { loaded.append($0) }
        pump { store.state(for: "a.png") == .loaded && store.state(for: "missing.png") == .failed }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(store.state(for: "a.png"), .loaded)
        XCTAssertNotNil(store.image(for: "a.png"))
        XCTAssertEqual(store.state(for: "missing.png"), .failed)
        XCTAssertEqual(loaded.filter { $0 == "a.png" }, ["a.png"])
    }
}
