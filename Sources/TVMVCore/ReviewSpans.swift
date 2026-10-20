import Foundation

/// What the native editor's layout needs from review markup: which runs to
/// hide (delimiters and refs, revealed together on demand), how to style the
/// text between them, what spell checking skips, and which definition blocks
/// collapse out of the flow. Pure data; `MarkdownLayout` decides how it looks.
extension ReviewMarkup {

    public struct Span: Equatable, Sendable {
        public enum Role: Sendable {
            /// `{==`, `==}`, `~>` and the rest: hidden, a reveal unit with its anchor.
            case delimiter
            /// The `[^id]` after a range anchor: hidden like the delimiters.
            case ref
            case highlight, insertion, deletion
            /// The two sides of a substitution: struck, then underlined.
            case substitutionOld, substitutionNew
            /// A point comment's `[^id]`, shown as a small superscript marker.
            case pointMarker
            /// A whole thread definition block, collapsed out of the flow.
            case definition
        }

        public var range: Range<Int>
        public var role: Role
        public var id: String

        public init(range: Range<Int>, role: Role, id: String) {
            self.range = range
            self.role = role
            self.id = id
        }

        public var isHidden: Bool { role == .delimiter || role == .ref }

        /// Ids, refs and the thread syntax are not prose.
        public var isSpellingExempt: Bool {
            switch role {
            case .delimiter, .ref, .pointMarker, .definition: return true
            case .highlight, .insertion, .deletion, .substitutionOld, .substitutionNew: return false
            }
        }
    }

    /// Every anchor's parts and every thread definition, sorted and disjoint.
    public static func spans(_ review: Review) -> [Span] {
        var spans: [Span] = []
        for anchor in review.anchors {
            let id = anchor.id
            func add(_ range: Range<Int>, _ role: Span.Role) {
                spans.append(Span(range: range, role: role, id: id))
            }
            let opener = anchor.range.lowerBound..<anchor.inner.lowerBound
            let closer = anchor.inner.upperBound..<anchor.ref.lowerBound
            switch anchor.kind {
            case .point:
                add(anchor.ref, .pointMarker)
                continue
            case .highlight, .insertion, .deletion:
                let role: Span.Role = anchor.kind == .highlight ? .highlight
                    : anchor.kind == .insertion ? .insertion : .deletion
                add(opener, .delimiter)
                add(anchor.inner, role)
                add(closer, .delimiter)
            case .substitution:
                guard let old = anchor.old, let new = anchor.new else { continue }
                add(opener, .delimiter)
                add(old, .substitutionOld)
                add(old.upperBound..<new.lowerBound, .delimiter)
                add(new, .substitutionNew)
                add(closer, .delimiter)
            }
            add(anchor.ref, .ref)
        }
        for thread in review.threads {
            spans.append(Span(range: thread.range, role: .definition, id: thread.id))
        }
        return spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
