import Foundation

/// Applies editor patches to a document string.
///
/// The editor page bridges CodeMirror changes as `[from, to, insert]` triples
/// in UTF-16 code units, coordinatized against the document as of the last
/// flush (a composed ChangeSet's original-side ranges: ascending and
/// non-overlapping). Applying them replaces shipping the complete document
/// across the WebKit bridge on every settled keystroke batch.
///
/// Apply is strict: any incoherent input (out-of-bounds, overlapping, or a
/// result whose length disagrees with the editor's report) returns nil so the
/// caller can fall back to a full-text resync instead of silently corrupting
/// the document.
public enum TextPatcher {

    public struct Patch: Equatable, Sendable {
        /// UTF-16 range in the pre-patch document.
        public var from: Int
        public var to: Int
        public var insert: String

        public init(from: Int, to: Int, insert: String) {
            self.from = from
            self.to = to
            self.insert = insert
        }
    }

    /// Apply `patches` (ascending, non-overlapping) to `text`.
    /// - Parameter expectedUTF16Length: the editor's post-change document
    ///   length; a mismatch after applying means the two sides diverged.
    public static func apply(
        _ patches: [Patch],
        to text: String,
        expectedUTF16Length: Int? = nil
    ) -> String? {
        let result = NSMutableString(string: text)

        // Validate coherence against the ORIGINAL text before mutating.
        var previousEnd = 0
        for patch in patches {
            guard patch.from >= previousEnd,          // ascending, non-overlapping
                  patch.to >= patch.from,
                  patch.to <= result.length
            else { return nil }
            previousEnd = patch.to
        }

        // Reverse order keeps earlier offsets valid while later text shifts.
        for patch in patches.reversed() {
            result.replaceCharacters(
                in: NSRange(location: patch.from, length: patch.to - patch.from),
                with: patch.insert
            )
        }

        if let expected = expectedUTF16Length, result.length != expected {
            return nil
        }
        return result as String
    }
}
