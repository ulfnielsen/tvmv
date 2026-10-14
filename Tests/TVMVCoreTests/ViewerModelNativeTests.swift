import XCTest
@testable import TVMVCore

@MainActor
final class ViewerModelNativeTests: XCTestCase {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvmv-native-\(UUID().uuidString).md")
        try contents.data(using: .utf8)!.write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            let path = url.standardizedFileURL.path
            for key in ["readingOffset.", "bookmarkOffset.", "readingPosition.", "bookmark."] {
                UserDefaults.standard.removeObject(forKey: key + path)
            }
        }
        return url
    }

    func testExternalChangeIsHandedToTheNativeView() async throws {
        let url = try tempFile("one\n")
        let model = ViewerModel(text: "one\n", fileURL: url)
        var adopted: [String] = []
        model.onExternalTextAdopted = { adopted.append($0) }
        try "two\n".write(to: url, atomically: true, encoding: .utf8)
        await model.reload()
        XCTAssertEqual(adopted, ["two\n"])
        XCTAssertEqual(model.text, "two\n")
    }

    func testExternalChangeWithUnsavedEditsIsNotAdopted() async throws {
        let url = try tempFile("one\n")
        let model = ViewerModel(text: "one\n", fileURL: url)
        model.rendersPreview = false
        var adopted: [String] = []
        model.onExternalTextAdopted = { adopted.append($0) }
        model.textEdited("mine\n")
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        await model.reload()
        XCTAssertEqual(adopted, [])
        XCTAssertEqual(model.text, "mine\n")
        XCTAssertTrue(model.externalChangePending)
    }

    func testNativeReadingPositionAndBookmark() throws {
        let url = try tempFile("x\n")
        let model = ViewerModel(text: "x\n", fileURL: url)
        XCTAssertNil(model.nativeReadingPosition)
        model.nativeReadingChanged(offset: 120, progress: 0.25)
        XCTAssertEqual(model.nativeReadingPosition, .offset(120))
        XCTAssertEqual(model.readingProgress, 0.25)

        XCTAssertFalse(model.hasBookmark)
        model.nativeSaveBookmark(offset: 7)
        XCTAssertTrue(model.hasBookmark)
        XCTAssertEqual(model.nativeBookmark, .offset(7))
        XCTAssertTrue(ViewerModel(text: "x\n", fileURL: url).hasBookmark, "an offset bookmark survives reopening")
    }
}
