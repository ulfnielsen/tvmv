import Foundation

/// Caret and delete behavior around hidden markup, as pure functions of the
/// text and a hidden-character predicate. `isHidden(i)` is true when the
/// character at UTF-16 offset `i` is currently hidden markup.
public enum EditRules {

    /// The maximal run of hidden characters containing offset `i`.
    public static func hiddenRun(at i: Int, length: Int, isHidden: (Int) -> Bool) -> NSRange {
        var start = i, end = i
        while start > 0, isHidden(start - 1) { start -= 1 }
        while end < length, isHidden(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    static func isLineStart(_ i: Int, in text: NSString) -> Bool {
        i == 0 || text.character(at: i - 1) == 10
    }

    /// Where a zero-length caret requested at `location` should rest.
    ///
    /// - Inside a hidden run: pass over it in the direction of travel.
    /// - A run that begins a line (a heading's "# "): always rest after it,
    ///   so typing at a line's visual start stays inside the heading.
    /// - A run that is a whole collapsed line (code fence, setext underline):
    ///   moving forward lands after it; moving back lands at the end of the
    ///   previous line.
    public static func snapCaret(_ location: Int, movingForward: Bool, in text: NSString,
                                 isHidden: (Int) -> Bool) -> Int {
        let length = text.length
        let insideRun = location > 0 && location < length && isHidden(location - 1) && isHidden(location)
        let beforeLinePrefix = location < length && isHidden(location) && isLineStart(location, in: text)
        guard insideRun || beforeLinePrefix else { return location }
        let run = hiddenRun(at: location, length: length, isHidden: isHidden)
        let wholeLine = isLineStart(run.location, in: text)
            && NSMaxRange(run) > run.location && text.character(at: NSMaxRange(run) - 1) == 10
        if wholeLine {
            if movingForward || run.location == 0 { return NSMaxRange(run) }
            return run.location - 1
        }
        if isLineStart(run.location, in: text) { return NSMaxRange(run) }
        return movingForward ? NSMaxRange(run) : run.location
    }

    public enum DeleteAction: Equatable {
        /// Let the text view delete as requested.
        case allow
        /// Delete this range instead.
        case replace(NSRange)
        /// Do nothing.
        case ignore
    }

    /// A one-character delete that lands on hidden markup.
    ///
    /// - Backspace right after a hidden line prefix ("# ") removes the prefix.
    /// - Backspace or forward-delete into a collapsed line does nothing (it
    ///   would join a code block to its neighbor).
    /// - Otherwise the nearest visible character in that direction goes.
    public static func retargetDelete(_ range: NSRange, caret: Int, in text: NSString,
                                      isHidden: (Int) -> Bool) -> DeleteAction {
        guard range.length == 1, isHidden(range.location) else { return .allow }
        let length = text.length
        let run = hiddenRun(at: range.location, length: length, isHidden: isHidden)
        let backward = caret == NSMaxRange(range)
        let wholeLine = isLineStart(run.location, in: text)
            && text.character(at: NSMaxRange(run) - 1) == 10
        if wholeLine { return .ignore }
        if backward && isLineStart(run.location, in: text) { return .replace(run) }
        var target = backward ? run.location - 1 : NSMaxRange(run)
        while target >= 0, target < length, isHidden(target) { target += backward ? -1 : 1 }
        guard target >= 0, target < length else { return .ignore }
        return .replace(NSRange(location: target, length: 1))
    }

    /// Wrap a non-empty selection in `marker` (or unwrap it if it already is
    /// wrapped). Returns the patches (ascending, against the current text) and
    /// the selection afterwards; nil when there is nothing to do.
    public static func toggleWrap(_ selection: NSRange, marker: String, in text: NSString)
        -> (patches: [TextPatcher.Patch], selection: NSRange)? {
        guard selection.length > 0 else { return nil }
        let k = (marker as NSString).length
        let before = NSRange(location: selection.location - k, length: k)
        let after = NSRange(location: NSMaxRange(selection), length: k)
        if before.location >= 0, NSMaxRange(after) <= text.length,
           text.substring(with: before) == marker, text.substring(with: after) == marker {
            return ([.init(from: before.location, to: NSMaxRange(before), insert: ""),
                     .init(from: after.location, to: NSMaxRange(after), insert: "")],
                    NSRange(location: selection.location - k, length: selection.length))
        }
        return ([.init(from: selection.location, to: selection.location, insert: marker),
                 .init(from: NSMaxRange(selection), to: NSMaxRange(selection), insert: marker)],
                NSRange(location: selection.location + k, length: selection.length))
    }
}
