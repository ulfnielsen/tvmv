import Foundation

/// Turns a preview click into a caret position in the Markdown source.
///
/// cmark's sourcepos is block-level: a rendered paragraph knows which source
/// lines it came from, but nothing inside it does. To land the caret on the word
/// the user actually clicked, boot.js reports the word under the pointer plus
/// which occurrence of that word it was within the block's rendered text, and
/// this looks the same occurrence up in the source lines of that block.
///
/// Rendered text and source text are not identical — markup characters are gone,
/// link URLs and image alt text are present in one and not the other — so the
/// ordinal can be off. Every mismatch degrades to "a nearby occurrence of the
/// right word in the right block", never to a wrong block.
public enum SourceClickResolver {

    /// A 1-based caret position. `column` counts UTF-16 code units, the unit
    /// CodeMirror uses for document offsets.
    public struct Target: Equatable, Sendable {
        public var line: Int
        public var column: Int

        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }
    }

    /// Find the `ordinal`-th whole-word occurrence of `word` in the source lines
    /// `startLine...endLine` (1-based, inclusive, clamped to the document).
    ///
    /// Returns the last occurrence when `ordinal` overshoots, and nil when the
    /// word does not appear in the block at all — the caller then falls back to
    /// the start of the block.
    public static func resolve(
        in text: String,
        word: String,
        ordinal: Int,
        startLine: Int,
        endLine: Int
    ) -> Target? {
        guard !word.isEmpty else { return nil }

        // `components` keeps a trailing empty line, which is harmless here and
        // makes the line numbering match the editor's.
        let lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }

        let first = max(1, min(startLine, lines.count))
        let last = max(first, min(max(startLine, endLine), lines.count))
        let wanted = max(1, ordinal)

        var seen = 0
        var lastMatch: Target?

        for number in first...last {
            for column in wholeWordColumns(of: word, in: lines[number - 1]) {
                seen += 1
                let target = Target(line: number, column: column)
                lastMatch = target
                if seen == wanted { return target }
            }
        }
        return lastMatch
    }

    /// 1-based UTF-16 columns of every whole-word occurrence of `word` in `line`,
    /// in order. "Whole word" means neither neighbour is a word character, so
    /// clicking "fox" never lands inside "foxglove".
    private static func wholeWordColumns(of word: String, in line: String) -> [Int] {
        var columns: [Int] = []
        var searchStart = line.startIndex

        while let found = line.range(of: word, range: searchStart..<line.endIndex) {
            let beforeOK = found.lowerBound == line.startIndex
                || !isWordCharacter(line[line.index(before: found.lowerBound)])
            let afterOK = found.upperBound == line.endIndex
                || !isWordCharacter(line[found.upperBound])

            if beforeOK && afterOK {
                let offset = line.utf16.distance(from: line.startIndex, to: found.lowerBound)
                columns.append(offset + 1)
            }
            // Step one character past the match start so overlapping candidates
            // (e.g. "aa" in "aaa") are still considered.
            searchStart = line.index(after: found.lowerBound)
            if searchStart >= line.endIndex { break }
        }
        return columns
    }

    /// Matches boot.js's `[\p{L}\p{N}_]` word class, so "grød" and "naïve" are
    /// single words on both sides of the bridge.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }
}
