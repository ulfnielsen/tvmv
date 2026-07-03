import XCTest
@testable import tvmv

@MainActor
final class ViewerModelEditingTests: XCTestCase {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvmv-test-\(UUID().uuidString).md")
        try contents.data(using: .utf8)!.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTextEditedSetsDirtyAndSaveWritesAndClearsIt() throws {
        let url = try tempFile("# hello\n")
        let model = ViewerModel(text: "# hello\n", fileURL: url, encoding: .utf8)
        XCTAssertFalse(model.isDirty)
        model.textEdited("# hello world\n")
        XCTAssertTrue(model.isDirty)
        model.save()
        XCTAssertFalse(model.isDirty)
        XCTAssertNil(model.saveError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# hello world\n")
    }

    func testEditingBackToSavedTextClearsDirty() throws {
        let url = try tempFile("a\n")
        let model = ViewerModel(text: "a\n", fileURL: url, encoding: .utf8)
        model.textEdited("ab\n")
        model.textEdited("a\n")
        XCTAssertFalse(model.isDirty)
    }

    func testReloadIgnoresOwnSaveEcho() async throws {
        // After save(), the FileWatcher will fire and call reload(); the disk
        // content equals our text, so nothing may change (no clobber loop).
        let url = try tempFile("a\n")
        let model = ViewerModel(text: "a\n", fileURL: url, encoding: .utf8)
        model.textEdited("b\n")
        model.save()
        await model.reload()
        XCTAssertEqual(model.text, "b\n")
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.externalChangePending)
    }

    func testExternalChangeWhileDirtySetsPendingAndKeepsEdits() async throws {
        let url = try tempFile("original\n")
        let model = ViewerModel(text: "original\n", fileURL: url, encoding: .utf8)
        model.textEdited("edited\n")
        try "external\n".data(using: .utf8)!.write(to: url)
        await model.reload()
        XCTAssertTrue(model.externalChangePending)
        XCTAssertEqual(model.text, "edited\n")   // edits never clobbered
        XCTAssertTrue(model.isDirty)
    }

    func testExternalChangeWhileCleanUpdatesText() async throws {
        let url = try tempFile("original\n")
        let model = ViewerModel(text: "original\n", fileURL: url, encoding: .utf8)
        try "external\n".data(using: .utf8)!.write(to: url)
        await model.reload()
        XCTAssertEqual(model.text, "external\n")
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.externalChangePending)
    }

    func testDiscardAndReloadDropsEditsAndClearsPending() async throws {
        let url = try tempFile("original\n")
        let model = ViewerModel(text: "original\n", fileURL: url, encoding: .utf8)
        model.textEdited("edited\n")
        try "external\n".data(using: .utf8)!.write(to: url)
        await model.reload()
        XCTAssertTrue(model.externalChangePending)
        await model.discardAndReload()
        XCTAssertEqual(model.text, "external\n")
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.externalChangePending)
    }

    func testDiscardAndReloadWhenDiskEqualsLastSavedClearsFlags() async throws {
        // External process reverted the file to exactly what we last saved
        // (e.g. git checkout): discard must still clear flags and adopt it.
        let url = try tempFile("original\n")
        let model = ViewerModel(text: "original\n", fileURL: url, encoding: .utf8)
        model.textEdited("edited\n")
        XCTAssertTrue(model.isDirty)
        await model.discardAndReload()
        XCTAssertEqual(model.text, "original\n")
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.externalChangePending)
    }

    func testExternalWriteMatchingBufferClearsDirty() async throws {
        let url = try tempFile("original\n")
        let model = ViewerModel(text: "original\n", fileURL: url, encoding: .utf8)
        model.textEdited("edited\n")
        XCTAssertTrue(model.isDirty)
        // An external writer saves exactly what our buffer holds.
        try "edited\n".data(using: .utf8)!.write(to: url)
        await model.reload()
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.externalChangePending)
        XCTAssertEqual(model.text, "edited\n")
    }

    func testSaveFailureSetsErrorAndStaysDirty() throws {
        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvmv-missing-\(UUID().uuidString)")
        let url = missingDir.appendingPathComponent("f.md")   // parent doesn't exist
        let model = ViewerModel(text: "a", fileURL: url, encoding: .utf8)
        model.textEdited("b")
        model.save()
        XCTAssertNotNil(model.saveError)
        XCTAssertTrue(model.isDirty)
    }

    func testSaveRoundTripsLatin1Encoding() throws {
        let url = try tempFile("x")
        let model = ViewerModel(text: "café\n", fileURL: url, encoding: .isoLatin1)
        model.textEdited("café olé\n")
        model.save()
        let decoded = MarkdownText.decode(try Data(contentsOf: url))
        XCTAssertEqual(decoded.text, "café olé\n")
        XCTAssertEqual(decoded.encoding, .isoLatin1)
    }

    func testCRLFDocumentEditorEchoStaysCleanAndSavePreservesCRLF() async throws {
        // Root-cause regression for spurious quit prompts: CodeMirror
        // normalizes CRLF to LF, so the model must hold normalized text
        // (making the editor's seed/flush echo a no-op) and restore the
        // original endings on save.
        let url = try tempFile("line one\r\nline two\r\n")
        let d = MarkdownText.decode(try Data(contentsOf: url))
        let model = ViewerModel(text: d.text, fileURL: url,
                                encoding: d.encoding, lineEnding: d.lineEnding)
        // The editor's seed/flush echo delivers CM's LF-normalized doc.
        model.textEdited("line one\nline two\n")
        XCTAssertFalse(model.isDirty)   // no actual change → no quit prompt

        // A real edit saves with the file's original endings.
        model.textEdited("line one\nline two\nline three\n")
        model.save()
        XCTAssertEqual(try Data(contentsOf: url),
                       Data("line one\r\nline two\r\nline three\r\n".utf8))
        // The watcher echo of our own save must still read as clean.
        await model.reload()
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.externalChangePending)
    }

    func testFlushAndSaveWithoutBridgeSavesCachedText() async throws {
        // The editor bridge is gone (pane closed / page dead): flushAndSave
        // must still write the model's cached text rather than losing the save.
        let url = try tempFile("# hello\n")
        let model = ViewerModel(text: "# hello\n", fileURL: url, encoding: .utf8)
        model.textEdited("# hello world\n")
        await model.flushAndSave()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# hello world\n")
    }
}
