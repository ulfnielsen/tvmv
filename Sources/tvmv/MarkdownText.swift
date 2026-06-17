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
}
