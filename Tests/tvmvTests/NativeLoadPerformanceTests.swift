import XCTest
import AppKit
@testable import tvmv

/// Timings for the native view on a page of tables and inline images. They
/// run only with `TVMV_PERF=1` in the environment (see TVMVCoreTests'
/// PerformanceTests); the always-on tests guard the shape of the work.
@MainActor
final class NativeLoadPerformanceTests: XCTestCase {
    private var perfEnabled: Bool { ProcessInfo.processInfo.environment["TVMV_PERF"] == "1" }

    func testLoadAndSettleTablesWithInlineImages() throws {
        try XCTSkipUnless(perfEnabled, "set TVMV_PERF=1 to time loading")
        let count = Int(ProcessInfo.processInfo.environment["TVMV_PERF_TABLES"] ?? "") ?? 300
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tvmv-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("img"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        var text = "# Tables\n\n"
        for i in 0..<count {
            try png.write(to: folder.appendingPathComponent("img/i\(i).png"))
            text += "Para \(i) ![i](img/i\(i).png) text.\n\n| a | b |\n|---|---|\n| x | y |\n\n"
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let view = DocumentTextView.make()
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = view
        window.contentView!.addSubview(scroll)
        view.documentURL = folder.appendingPathComponent("doc.md")
        let start = Date()
        view.load(text)
        let loaded = Date()
        let deadline = Date().addingTimeInterval(300)
        while (0..<count).contains(where: { view.imageState(for: "img/i\($0).png") == .loading }), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let settled = Date()
        print(String(format: "PERF tables=%d load=%.2fs settle=%.2fs", count,
                     loaded.timeIntervalSince(start), settled.timeIntervalSince(loaded)))
    }
}
