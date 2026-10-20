import XCTest
@testable import TVMVCore

final class ReadingPositionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private let file = URL(fileURLWithPath: "/tmp/doc.md")

    override func setUp() {
        suite = "ReadingPositionStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testNothingStoredIsNil() {
        let store = ReadingPositionStore(fileURL: file, defaults: defaults)
        XCTAssertNil(store.readingPosition)
        XCTAssertNil(store.bookmark)
    }

    func testLegacyFractionsAreReadUntilAnOffsetIsWritten() {
        defaults.set(0.4, forKey: "readingPosition./tmp/doc.md")
        defaults.set(0.7, forKey: "bookmark./tmp/doc.md")
        let store = ReadingPositionStore(fileURL: file, defaults: defaults)
        XCTAssertEqual(store.readingPosition, .fraction(0.4))
        XCTAssertEqual(store.bookmark, .fraction(0.7))

        store.setReadingOffset(1234)
        store.setBookmarkOffset(99)
        XCTAssertEqual(store.readingPosition, .offset(1234))
        XCTAssertEqual(store.bookmark, .offset(99))
    }

    func testClearBookmarkRemovesOffsetAndLegacyFractionOnly() {
        defaults.set(0.7, forKey: "bookmark./tmp/doc.md")
        let store = ReadingPositionStore(fileURL: file, defaults: defaults)
        store.setBookmarkOffset(99)
        store.setReadingOffset(5)

        store.clearBookmark()
        XCTAssertNil(store.bookmark, "neither the offset nor the legacy fraction survives")
        XCTAssertNil(ReadingPositionStore(fileURL: file, defaults: defaults).bookmark)
        XCTAssertEqual(store.readingPosition, .offset(5))

        store.clearBookmark()   // nothing left: harmless
        XCTAssertNil(store.bookmark)
        store.setBookmarkOffset(3)
        XCTAssertEqual(store.bookmark, .offset(3))
    }
}
