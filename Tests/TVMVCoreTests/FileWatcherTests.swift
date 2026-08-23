import XCTest
@testable import TVMVCore

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

    func testMissingFileIsPickedUpAfterCreation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("late.md")

        let counter = Counter()
        let watcher = FileWatcher(url: file, debounceMilliseconds: 50) {
            counter.bump()
        }
        watcher.start()
        try await Task.sleep(nanoseconds: 300_000_000)

        try "hello".write(to: file, atomically: true, encoding: .utf8)
        // Attachment happens on the retry cadence; once attached, a write fires.
        for _ in 0..<40 {
            try "hello again".write(to: file, atomically: false, encoding: .utf8)
            try await Task.sleep(nanoseconds: 100_000_000)
            if counter.value > 0 { break }
        }
        watcher.stop()
        XCTAssertGreaterThanOrEqual(counter.value, 1,
            "a file created after start() should still get watched")
    }

    func testDeleteThenRecreateKeepsWatching() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try "v1".write(to: file, atomically: true, encoding: .utf8)

        let counter = Counter()
        let watcher = FileWatcher(url: file, debounceMilliseconds: 50) {
            counter.bump()
        }
        watcher.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        try FileManager.default.removeItem(at: file)
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterDelete = counter.value
        XCTAssertGreaterThanOrEqual(afterDelete, 1, "deletion should notify")

        try "v2".write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            try "v3".write(to: file, atomically: false, encoding: .utf8)
            if counter.value > afterDelete { break }
        }
        watcher.stop()
        XCTAssertGreaterThan(counter.value, afterDelete,
            "writes after recreation should still notify")
    }

    func testRetryBacksOffWhileFileStaysMissing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("never.md")

        let watcher = FileWatcher(url: file) { }
        watcher.start()
        // At a fixed 100 ms cadence this would still read 100 after any wait;
        // with backoff the delay must have grown well past the initial value.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let delay = watcher.retryDelayForTesting()
        watcher.stop()
        XCTAssertGreaterThan(delay, 400,
            "retry delay should back off while the path stays missing (was \(delay) ms)")
    }

    func testStopDuringRetryAndReleaseDoesNotCrash() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for _ in 0..<20 {
            let watcher = FileWatcher(url: dir.appendingPathComponent("gone.md")) { }
            watcher.start()
            try await Task.sleep(nanoseconds: 20_000_000)
            watcher.stop()
        }
        // Watchers released while their retry timers may still be pending.
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    func testRepeatedLifecycleKeepsDescriptorCountStable() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        func openDescriptors() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }

        // Warm up dispatch machinery so its lazily-created descriptors don't
        // count against the measurement.
        for _ in 0..<3 {
            let w = FileWatcher(url: file) { }
            w.start()
            try await Task.sleep(nanoseconds: 30_000_000)
            w.stop()
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        let before = openDescriptors()
        for _ in 0..<30 {
            let w = FileWatcher(url: file) { }
            w.start()
            try await Task.sleep(nanoseconds: 15_000_000)
            w.stop()
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let after = openDescriptors()

        XCTAssertLessThanOrEqual(after, before + 5,
            "descriptors should not accumulate across watcher lifecycles (\(before) -> \(after))")
    }
}

@MainActor final class Counter { private(set) var value = 0; func bump() { value += 1 } }
