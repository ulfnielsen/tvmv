import TVMVCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Read-only `FileDocument` for Markdown files.
///
/// Used via `DocumentGroup(viewing:)`, which suppresses all save/edit UI.
/// `fileWrapper(configuration:)` is required by the protocol but is never
/// called for a viewer; it throws `CocoaError(.featureUnsupported)`.
struct MarkdownDocument: FileDocument {
    /// The decoded document text.
    let text: String
    /// Which encoding successfully decoded the source bytes.
    let encodingUsed: TextEncodingUsed
    /// Which newline style the source used (text is LF-normalized; saves restore this).
    let lineEndingUsed: LineEndingUsed

    // `net.daringfireball.markdown` is system-known on macOS 26.
    static let markdownType = UTType(importedAs: "net.daringfireball.markdown")

    static var readableContentTypes: [UTType] { [markdownType] }

    init(configuration: ReadConfiguration) throws {
        // ReadConfiguration.file is a FileWrapper; read bytes via .regularFileContents.
        guard let bytes = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // Decode with a fallback chain so the document always shows something.
        // The raw bytes are deliberately NOT retained — nothing reads them
        // after decoding, and keeping them doubles per-document memory.
        let decoded = MarkdownText.decode(bytes)
        self.text = decoded.text
        self.encodingUsed = decoded.encoding
        self.lineEndingUsed = decoded.lineEnding
    }

    // This app never writes. DocumentGroup(viewing:) means this is never invoked,
    // but FileDocument requires the method (no default for fileWrapper).
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported)
    }
}
