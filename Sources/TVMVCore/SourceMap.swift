import Foundation

/// Converts cmark's 1-based (line, byte column) source positions into UTF-16
/// offsets — the unit NSString, NSTextView and TextPatcher use.
///
/// cmark counts columns in UTF-8 bytes. A position can name any byte of a
/// multi-byte character, so offsets snap to the character containing it, and
/// exclusive ends snap forward to the next character boundary.
public struct SourceMap {
    private let bytes: [UInt8]
    /// Byte offset where each line starts (index 0 is line 1).
    private let lineStarts: [Int]
    /// UTF-16 offset of the character containing each byte; one extra entry
    /// for the end of the text.
    private let utf16AtByte: [Int32]

    public init(_ text: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var utf16AtByte: [Int32] = []
        utf16AtByte.reserveCapacity(text.utf8.count + 1)
        var lineStarts = [0]
        var u16: Int32 = 0
        for scalar in text.unicodeScalars {
            let encoded = UTF8.encode(scalar)!
            for byte in encoded {
                bytes.append(byte)
                utf16AtByte.append(u16)
            }
            u16 += Int32(UTF16.width(scalar))
            if scalar == "\n" { lineStarts.append(bytes.count) }
        }
        utf16AtByte.append(u16)
        self.bytes = bytes
        self.lineStarts = lineStarts
        self.utf16AtByte = utf16AtByte
    }

    /// UTF-16 offset of the character at (line, column); nil when cmark
    /// reported no position (line 0) or the position is out of range.
    public func offset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= lineStarts.count, column >= 1 else { return nil }
        let byte = lineStarts[line - 1] + column - 1
        guard byte < utf16AtByte.count else { return nil }
        return Int(utf16AtByte[byte])
    }

    /// UTF-16 offset just past the character at (line, column). Column 0
    /// means "the end of the previous line", which cmark uses for container
    /// blocks that end at a blank line.
    public func endOffset(line: Int, column: Int) -> Int? {
        guard line >= 1, line <= lineStarts.count, column >= 0 else { return nil }
        var byte = lineStarts[line - 1] + column
        guard byte <= bytes.count else { return nil }
        while byte < bytes.count, bytes[byte] & 0xC0 == 0x80 { byte += 1 }   // skip continuation bytes
        return Int(utf16AtByte[byte])
    }

    /// The UTF-16 range for cmark's inclusive start/end positions.
    public func range(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) -> NSRange? {
        guard let start = offset(line: startLine, column: startColumn),
              let end = endOffset(line: endLine, column: endColumn), end >= start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
