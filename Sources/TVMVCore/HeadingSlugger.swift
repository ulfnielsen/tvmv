import Foundation

/// Swift port of boot.js's GitHub heading-slug algorithm, so the native
/// outline and `#anchor` links resolve exactly as the web reader's did:
/// lowercase; strip everything but letters, numbers, marks, "_", "-", and
/// spaces; spaces become hyphens; runs of hyphens collapse; duplicates get
/// "-1", "-2", … (and a deduped slug is itself taken).
public struct HeadingSlugger {
    private var seen: [String: Int] = [:]

    public init() {}

    public static func base(_ text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            switch scalar.properties.generalCategory {
            // \p{L}, \p{N}, \p{M} — exactly the classes boot.js keeps.
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .nonspacingMark, .spacingMark, .enclosingMark:
                out.unicodeScalars.append(scalar)
            default:
                if scalar == "_" || scalar == "-" { out.unicodeScalars.append(scalar) }
                else if scalar == " " { out.unicodeScalars.append("-") }
            }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out
    }

    public mutating func slug(_ text: String) -> String {
        let s = Self.base(text)
        guard let count = seen[s] else { seen[s] = 0; return s }
        var n = count + 1
        var candidate = "\(s)-\(n)"
        while seen[candidate] != nil { n += 1; candidate = "\(s)-\(n)" }
        seen[s] = n
        seen[candidate] = 0
        return candidate
    }
}
