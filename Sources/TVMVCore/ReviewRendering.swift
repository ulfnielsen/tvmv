import Foundation

/// Review markup in rendered HTML (print, QuickLook, the iOS/Linux reader).
///
/// cmark strips raw HTML, so `<mark>`/`<ins>`/`<del>` cannot be written into
/// the Markdown before parsing. Instead a pre-pass swaps each anchor's
/// delimiters for private-use sentinels, cmark renders them as ordinary text,
/// and a post-pass turns them into tags carrying `data-rv`. The `[^rv-…]`
/// refs stay in the source, so with footnotes on the threads render as GFM
/// footnotes.
///
/// Every sentinel has the UTF-8 length of the delimiter it replaces, so lines
/// keep their byte lengths and `data-sourcepos` columns match the file as
/// written. Like `ReviewMarkup.swift`, this file depends on Foundation only,
/// for the QuickLook build.
extension ReviewMarkup {

    private enum Sentinel {
        // `{==` `==}` `{++` `++}` `{--` `--}` `{~~` → U+E000…U+E006, 3 bytes each.
        static let highlightOpen: Unicode.Scalar = "\u{E000}"
        static let highlightClose: Unicode.Scalar = "\u{E001}"
        static let insertionOpen: Unicode.Scalar = "\u{E002}"
        static let insertionClose: Unicode.Scalar = "\u{E003}"
        static let deletionOpen: Unicode.Scalar = "\u{E004}"
        static let deletionClose: Unicode.Scalar = "\u{E005}"
        static let substitutionOpen: Unicode.Scalar = "\u{E006}"
        // `~>` is two bytes and `~~}` three; their sentinels swap those
        // lengths, which keeps a one-line substitution's byte count exact.
        static let substitutionSeparator: Unicode.Scalar = "\u{E007}"
        static let substitutionClose: Unicode.Scalar = "\u{80}"

        static let all: Set<Unicode.Scalar> = [
            highlightOpen, highlightClose, insertionOpen, insertionClose, deletionOpen,
            deletionClose, substitutionOpen, substitutionSeparator, substitutionClose,
        ]

        /// The delimiter each sentinel stands for, restored where a tag
        /// cannot go.
        static let literal: [Unicode.Scalar: String] = [
            highlightOpen: "{==", highlightClose: "==}", insertionOpen: "{++",
            insertionClose: "++}", deletionOpen: "{--", deletionClose: "--}",
            substitutionOpen: "{~~", substitutionSeparator: "~>", substitutionClose: "~~}",
        ]

        static let close: [Unicode.Scalar: Unicode.Scalar] = [
            highlightOpen: highlightClose, insertionOpen: insertionClose,
            deletionOpen: deletionClose, substitutionOpen: substitutionClose,
        ]
    }

    /// The Markdown with anchor delimiters swapped for sentinels, or nil when
    /// review rendering does not apply: no `rv-` refs at all, or a source that
    /// already contains a sentinel character and so cannot be decoded safely.
    static func sentinelEncoded(_ markdown: String) -> String? {
        guard markdown.contains("[^rv-"),
              !markdown.unicodeScalars.contains(where: Sentinel.all.contains)
        else { return nil }

        let review = parse(markdown)
        var swaps: [(range: Range<Int>, sentinel: Unicode.Scalar)] = []
        for anchor in review.anchors {
            let opener = anchor.range.lowerBound..<anchor.inner.lowerBound
            let closer = anchor.inner.upperBound..<anchor.ref.lowerBound
            switch anchor.kind {
            case .point:
                continue
            case .highlight:
                swaps += [(opener, Sentinel.highlightOpen), (closer, Sentinel.highlightClose)]
            case .insertion:
                swaps += [(opener, Sentinel.insertionOpen), (closer, Sentinel.insertionClose)]
            case .deletion:
                swaps += [(opener, Sentinel.deletionOpen), (closer, Sentinel.deletionClose)]
            case .substitution:
                guard let old = anchor.old, let new = anchor.new else { continue }
                swaps += [(opener, Sentinel.substitutionOpen),
                          (old.upperBound..<new.lowerBound, Sentinel.substitutionSeparator),
                          (closer, Sentinel.substitutionClose)]
            }
        }

        let result = NSMutableString(string: markdown)
        for swap in swaps.reversed() {
            result.replaceCharacters(
                in: NSRange(location: swap.range.lowerBound, length: swap.range.count),
                with: String(Character(swap.sentinel)))
        }
        return result as String
    }

    /// Turn the sentinels in cmark's HTML into tags, and break `rv-` thread
    /// footnotes into one line per entry.
    static func sentinelDecoded(_ html: String) -> String {
        breakThreadEntries(tagged(html))
    }

    private static func tagged(_ html: String) -> String {
        let scalars = html.unicodeScalars
        // Pieces, with placeholders for opening tags whose id is only known
        // once the closer (and the footnote ref after it) is reached.
        var pieces: [String] = []
        var current = ""
        var open: [(sentinel: Unicode.Scalar, placeholders: [Int])] = []
        var inTag = false

        func placeholder() -> Int {
            pieces.append(current)
            current = ""
            pieces.append("")
            return pieces.count - 1
        }

        var index = scalars.startIndex
        while index != scalars.endIndex {
            let scalar = scalars[index]
            let next = scalars.index(after: index)
            defer { index = next }

            if scalar == "<" { inTag = true } else if scalar == ">" { inTag = false }
            guard Sentinel.all.contains(scalar) else {
                current.unicodeScalars.append(scalar)
                continue
            }
            // Inside an attribute (an image's alt text) a tag cannot go.
            if inTag {
                current += Sentinel.literal[scalar]!
                continue
            }

            if Sentinel.close[scalar] != nil {
                open.append((scalar, [placeholder()]))
            } else if scalar == Sentinel.substitutionSeparator,
                      open.last?.sentinel == Sentinel.substitutionOpen {
                open[open.count - 1].placeholders.append(placeholder())
            } else if let last = open.last, Sentinel.close[last.sentinel] == scalar {
                open.removeLast()
                let id = refID(in: scalars[next...])
                let attribute = id.map { " data-rv=\"\($0)\"" } ?? ""
                switch last.sentinel {
                case Sentinel.highlightOpen:
                    pieces[last.placeholders[0]] = "<mark\(attribute)>"
                    current += "</mark>"
                case Sentinel.insertionOpen:
                    pieces[last.placeholders[0]] = "<ins\(attribute)>"
                    current += "</ins>"
                case Sentinel.deletionOpen:
                    pieces[last.placeholders[0]] = "<del\(attribute)>"
                    current += "</del>"
                default:   // substitution
                    guard last.placeholders.count == 2 else {
                        for slot in last.placeholders { pieces[slot] = "{~~" }
                        current += "~~}"
                        break
                    }
                    pieces[last.placeholders[0]] = "<del\(attribute)>"
                    pieces[last.placeholders[1]] = "</del><ins\(attribute)>"
                    current += "</ins>"
                }
            } else {
                current += Sentinel.literal[scalar]!
            }
        }
        // Anything still open never met its closer in the output: restore it.
        for unclosed in open {
            pieces[unclosed.placeholders[0]] = Sentinel.literal[unclosed.sentinel]!
            for slot in unclosed.placeholders.dropFirst() { pieces[slot] = "~>" }
        }
        return pieces.joined() + current
    }

    /// The id of the `[^rv-…]` ref straight after a closer: rendered as a
    /// footnote link when its thread exists, or left as literal text when not.
    private static func refID(in rest: Substring.UnicodeScalarView) -> String? {
        let text = Substring(rest).prefix(80)
        for prefix in ["<sup class=\"footnote-ref\"><a href=\"#fn-", "[^"] where text.hasPrefix(prefix) {
            let id = text.dropFirst(prefix.count)
                .prefix { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
            if id.hasPrefix("rv-"), id.count > 3 { return String(id) }
        }
        return nil
    }

    private static let threadParagraph = try! NSRegularExpression(
        pattern: "(<li id=\"fn-rv-[a-z0-9]+\">\\n<p[^>]*>)(.*?)(</p>)",
        options: [.dotMatchesLineSeparators])
    private static let entryBreak = try! NSRegularExpression(
        pattern: "\\n(?=@\\S+ \\d{4}-\\d{2}-\\d{2}( suggestion)?:)")

    /// Each thread entry on its own line: the soft breaks between entries
    /// become hard breaks inside `rv-` footnotes only.
    private static func breakThreadEntries(_ html: String) -> String {
        let result = NSMutableString(string: html)
        let matches = threadParagraph.matches(
            in: html, range: NSRange(location: 0, length: result.length))
        for match in matches.reversed() {
            let body = match.range(at: 2)
            let replaced = entryBreak.stringByReplacingMatches(
                in: result.substring(with: body), range: NSRange(location: 0, length: body.length),
                withTemplate: "<br />\n")
            result.replaceCharacters(in: body, with: replaced)
        }
        return result as String
    }
}
