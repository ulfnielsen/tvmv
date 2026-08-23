import Foundation

/// Records which text encoding successfully decoded the source bytes.
public enum TextEncodingUsed: String, Sendable {
    case utf8, utf16, isoLatin1
}

/// Records which newline style the source bytes used.
public enum LineEndingUsed: String, Sendable {
    case lf, crlf, cr
}

/// Decodes Markdown bytes with a fallback chain so a document always shows
/// something: UTF-8 → UTF-16 (BOM) → ISO Latin-1 (maps every byte).
///
/// Decoded text is always LF-normalized: CodeMirror normalizes its document
/// the same way, so an untouched file must never compare "dirty" against the
/// editor's echo. The original newline style is recorded and restored by
/// `encode`, so saves round-trip the file's line endings byte-exactly.
public enum MarkdownText {
    public static func decode(_ data: Data) -> (text: String, encoding: TextEncodingUsed, lineEnding: LineEndingUsed) {
        let (raw, encoding) = decodeBytes(data)
        let lineEnding: LineEndingUsed =
            raw.contains("\r\n") ? .crlf : (raw.contains("\r") ? .cr : .lf)
        let text = lineEnding == .lf ? raw
            : raw.replacingOccurrences(of: "\r\n", with: "\n")
                 .replacingOccurrences(of: "\r", with: "\n")
        return (text, encoding, lineEnding)
    }

    private static func decodeBytes(_ data: Data) -> (String, TextEncodingUsed) {
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

    /// Encode LF-normalized text for writing back to disk, restoring the
    /// newline style and encoding the file was read with. Falls back to UTF-8
    /// when the text is no longer representable (e.g. emoji typed into a
    /// Latin-1 file) — a readable file beats a failed save.
    public static func encode(_ text: String, encoding: TextEncodingUsed, lineEnding: LineEndingUsed = .lf) -> Data {
        let restored: String = {
            switch lineEnding {
            case .lf: return text
            case .crlf: return text.replacingOccurrences(of: "\n", with: "\r\n")
            case .cr: return text.replacingOccurrences(of: "\n", with: "\r")
            }
        }()
        let preferred: String.Encoding = {
            switch encoding {
            case .utf8: return .utf8
            case .utf16: return .utf16      // emits a BOM, which decode requires
            case .isoLatin1: return .isoLatin1
            }
        }()
        return restored.data(using: preferred) ?? Data(restored.utf8)
    }
}
