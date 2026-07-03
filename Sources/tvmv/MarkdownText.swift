import Foundation

/// Records which text encoding successfully decoded the source bytes.
enum TextEncodingUsed: String, Sendable {
    case utf8, utf16, isoLatin1
}

/// Decodes Markdown bytes with a fallback chain so a document always shows
/// something: UTF-8 → UTF-16 (BOM) → ISO Latin-1 (maps every byte).
enum MarkdownText {
    static func decode(_ data: Data) -> (text: String, encoding: TextEncodingUsed) {
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        // Only trust UTF-16 when a BOM is present: String(_:encoding:.utf16) is
        // otherwise too permissive (e.g. returns "" for a lone 0xFF byte), which
        // would swallow Latin-1 content as empty text.
        if hasUTF16BOM(data), let s = String(data: data, encoding: .utf16) {
            return (s, .utf16)
        }
        return (String(data: data, encoding: .isoLatin1) ?? "", .isoLatin1)
    }

    private static func hasUTF16BOM(_ data: Data) -> Bool {
        let b = Array(data.prefix(2))
        return b.count == 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))
    }

    /// Encode text for writing back to disk in the encoding the file was read
    /// with, so saves round-trip the original encoding. Falls back to UTF-8
    /// when the text is no longer representable (e.g. emoji typed into a
    /// Latin-1 file) — a readable file beats a failed save.
    static func encode(_ text: String, encoding: TextEncodingUsed) -> Data {
        let preferred: String.Encoding = {
            switch encoding {
            case .utf8: return .utf8
            case .utf16: return .utf16      // emits a BOM, which decode requires
            case .isoLatin1: return .isoLatin1
            }
        }()
        return text.data(using: preferred) ?? Data(text.utf8)
    }
}
