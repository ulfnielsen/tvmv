import SwiftUI
import UniformTypeIdentifiers
import TVMVCore

/// Editable Markdown FileDocument: decode/encode through TVMV's text codec so
/// encodings and line endings round-trip byte-exactly, same as the Mac app.
struct MarkdownEditableDocument: FileDocument {
    static let markdownType = UTType(importedAs: "net.daringfireball.markdown")
    static var readableContentTypes: [UTType] { [markdownType] }

    var text: String
    let encodingUsed: TextEncodingUsed
    let lineEndingUsed: LineEndingUsed

    init(text: String = "# New Document\n") {
        self.text = text
        self.encodingUsed = .utf8
        self.lineEndingUsed = .lf
    }

    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoded = MarkdownText.decode(bytes)
        text = decoded.text
        encodingUsed = decoded.encoding
        lineEndingUsed = decoded.lineEnding
    }

    /// The bytes a save produces — the original encoding and newline style
    /// restored. Separate from fileWrapper so tests can hit it directly
    /// (FileDocument's configuration types have no public initializers).
    var encodedData: Data {
        MarkdownText.encode(text, encoding: encodingUsed, lineEnding: lineEndingUsed)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: encodedData)
    }
}
