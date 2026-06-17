import XCTest
@testable import tvmv

@MainActor
final class FileWatcherTests: XCTestCase {
    func testDebouncedSingleCallbackOnBurst() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try "start".write(to: file, atomically: true, encoding: .utf8)

        let counter = Counter()
        let watcher = FileWatcher(url: file, debounceMilliseconds: 120) {
            counter.bump()
        }
        watcher.start()
        try await Task.sleep(nanoseconds: 150_000_000)

        // Burst of writes within the debounce window.
        for i in 0..<5 {
            try "edit \(i)".write(to: file, atomically: false, encoding: .utf8)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        watcher.stop()

        XCTAssertGreaterThanOrEqual(counter.value, 1)
        XCTAssertLessThanOrEqual(counter.value, 2, "burst should coalesce, not fire per-write")
    }
}

@MainActor final class Counter { private(set) var value = 0; func bump() { value += 1 } }
