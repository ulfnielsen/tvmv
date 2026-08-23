import XCTest
import SwiftUI
import UniformTypeIdentifiers
@testable import TVMV
import TVMVCore

final class MarkdownEditableDocumentTests: XCTestCase {
    func testSaveEncodesThroughCodec() {
        var doc = MarkdownEditableDocument(text: "one\ntwo\n")
        doc.text += "three\n"
        XCTAssertEqual(doc.encodedData, Data("one\ntwo\nthree\n".utf8))
    }

    func testNewDocumentSeedIsUTF8LF() {
        let doc = MarkdownEditableDocument()
        XCTAssertEqual(doc.encodingUsed, .utf8)
        XCTAssertEqual(doc.lineEndingUsed, .lf)
        XCTAssertTrue(doc.text.hasPrefix("# "))
    }
}
