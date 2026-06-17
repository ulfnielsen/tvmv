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
    /// The raw source bytes as read from disk.
    let data: Data
    /// Which encoding successfully decoded `data`.
    let encodingUsed: TextEncodingUsed

    // `net.daringfireball.markdown` is system-known on macOS 26.
    static let markdownType = UTType(importedAs: "net.daringfireball.markdown")

    static var readableContentTypes: [UTType] { [markdownType] }

    init(configuration: ReadConfiguration) throws {
        // ReadConfiguration.file is a FileWrapper; read bytes via .regularFileContents.
        guard let bytes = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = bytes

        // Decode with a fallback chain so the document always shows something.
        let decoded = MarkdownText.decode(bytes)
        self.text = decoded.text
        self.encodingUsed = decoded.encoding
    }

    // This app never writes. DocumentGroup(viewing:) means this is never invoked,
    // but FileDocument requires the method (no default for fileWrapper).
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported)
    }
}
