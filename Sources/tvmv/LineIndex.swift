import Foundation

/// 1-based line ↔ UTF-16 offset conversions over a text buffer.
///
/// NSTextView selection/character ranges are UTF-16 code-unit indices and
/// cmark sourcepos lines are 1-based; these helpers bridge the two. O(n) per
/// call, which is fine for the document sizes a viewer handles and the
/// debounced call sites that use it.
enum LineIndex {
    /// The 1-based line number containing UTF-16 offset `offset` (clamped).
    static func line(at offset: Int, in text: String) -> Int {
        let s = text as NSString
        let upTo = max(0, min(offset, s.length))
        var line = 1
        for i in 0..<upTo where s.character(at: i) == 0x0A {
            line += 1
        }
        return line
    }

    /// The UTF-16 offset of the start of 1-based line `line`, clamped to the
    /// start of the last line when `line` exceeds the line count.
    static func offset(ofLine line: Int, in text: String) -> Int {
        let s = text as NSString
        var current = 1
        var start = 0
        var i = 0
        while i < s.length && current < line {
            if s.character(at: i) == 0x0A {
                current += 1
                start = i + 1
            }
            i += 1
        }
        return start
    }
}
