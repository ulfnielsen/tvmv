//! What the native editor's layout needs from review markup: which runs to
//! hide (delimiters and refs, revealed together on demand), how to style the
//! text between them, what spell checking skips, and which definition blocks
//! collapse out of the flow. A port of `Sources/TVMVCore/ReviewSpans.swift`;
//! pure data, and `layout.rs` decides how it looks.

use std::ops::Range;

use crate::review::{AnchorKind, Review};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SpanRole {
    /// `{==`, `==}`, `~>` and the rest: hidden, a reveal unit with its anchor.
    Delimiter,
    /// The `[^id]` after a range anchor: hidden like the delimiters.
    Ref,
    Highlight,
    Insertion,
    Deletion,
    /// The two sides of a substitution: struck, then underlined.
    SubstitutionOld,
    SubstitutionNew,
    /// A point comment's `[^id]`, shown as a small superscript marker.
    PointMarker,
    /// A whole thread definition block, collapsed out of the flow.
    Definition,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Span {
    pub range: Range<usize>,
    pub role: SpanRole,
    pub id: String,
}

impl Span {
    pub fn is_hidden(&self) -> bool {
        matches!(self.role, SpanRole::Delimiter | SpanRole::Ref)
    }

    /// Ids, refs and the thread syntax are not prose.
    pub fn is_spelling_exempt(&self) -> bool {
        matches!(
            self.role,
            SpanRole::Delimiter | SpanRole::Ref | SpanRole::PointMarker | SpanRole::Definition
        )
    }
}

/// Every anchor's parts and every thread definition, sorted and disjoint.
pub fn spans(review: &Review) -> Vec<Span> {
    let mut spans = Vec::new();
    for anchor in &review.anchors {
        let mut add = |range: Range<usize>, role: SpanRole| {
            spans.push(Span { range, role, id: anchor.id.clone() });
        };
        let opener = anchor.range.start..anchor.inner.start;
        let closer = anchor.inner.end..anchor.reference.start;
        match anchor.kind {
            AnchorKind::Point => {
                add(anchor.reference.clone(), SpanRole::PointMarker);
                continue;
            }
            AnchorKind::Highlight | AnchorKind::Insertion | AnchorKind::Deletion => {
                let role = match anchor.kind {
                    AnchorKind::Highlight => SpanRole::Highlight,
                    AnchorKind::Insertion => SpanRole::Insertion,
                    _ => SpanRole::Deletion,
                };
                add(opener, SpanRole::Delimiter);
                add(anchor.inner.clone(), role);
                add(closer, SpanRole::Delimiter);
            }
            AnchorKind::Substitution => {
                let (Some(old), Some(new)) = (anchor.old.clone(), anchor.new.clone()) else { continue };
                add(opener, SpanRole::Delimiter);
                add(old.clone(), SpanRole::SubstitutionOld);
                add(old.end..new.start, SpanRole::Delimiter);
                add(new, SpanRole::SubstitutionNew);
                add(closer, SpanRole::Delimiter);
            }
        }
        add(anchor.reference.clone(), SpanRole::Ref);
    }
    for thread in &review.threads {
        spans.push(Span { range: thread.range.clone(), role: SpanRole::Definition, id: thread.id.clone() });
    }
    spans.sort_by_key(|s| s.range.start);
    spans
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::review::parse;

    fn described(text: &str) -> Vec<String> {
        spans(&parse(text))
            .iter()
            .map(|s| format!("{:?} {} {:?}", s.role, s.id, &text[s.range.clone()]))
            .collect()
    }

    #[test]
    fn every_anchor_kind_and_definition() {
        let text = "{==a==}[^rv-aaaa] {++b++}[^rv-bbbb] {--c--}[^rv-bbbb] {~~d~>e~~}[^rv-bbbb] f[^rv-aaaa]\n\n\
                    [^rv-aaaa]: @x 2026-10-14: 1\n    @y 2026-10-14: 2\n[^rv-bbbb]: @x 2026-10-14 suggestion: 3\n";
        assert_eq!(
            described(text),
            [
                "Delimiter rv-aaaa \"{==\"", "Highlight rv-aaaa \"a\"", "Delimiter rv-aaaa \"==}\"",
                "Ref rv-aaaa \"[^rv-aaaa]\"",
                "Delimiter rv-bbbb \"{++\"", "Insertion rv-bbbb \"b\"", "Delimiter rv-bbbb \"++}\"",
                "Ref rv-bbbb \"[^rv-bbbb]\"",
                "Delimiter rv-bbbb \"{--\"", "Deletion rv-bbbb \"c\"", "Delimiter rv-bbbb \"--}\"",
                "Ref rv-bbbb \"[^rv-bbbb]\"",
                "Delimiter rv-bbbb \"{~~\"", "SubstitutionOld rv-bbbb \"d\"", "Delimiter rv-bbbb \"~>\"",
                "SubstitutionNew rv-bbbb \"e\"", "Delimiter rv-bbbb \"~~}\"", "Ref rv-bbbb \"[^rv-bbbb]\"",
                "PointMarker rv-aaaa \"[^rv-aaaa]\"",
                "Definition rv-aaaa \"[^rv-aaaa]: @x 2026-10-14: 1\\n    @y 2026-10-14: 2\\n\"",
                "Definition rv-bbbb \"[^rv-bbbb]: @x 2026-10-14 suggestion: 3\\n\"",
            ]
        );
    }

    #[test]
    fn spelling_exemptions() {
        let text = "{==a==}[^rv-aaaa] b[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-14: 1\n";
        let spans = spans(&parse(text));
        for span in &spans {
            let expected = !matches!(span.role, SpanRole::Highlight);
            assert_eq!(span.is_spelling_exempt(), expected, "{span:?}");
        }
        let hidden: Vec<SpanRole> = spans.iter().filter(|s| s.is_hidden()).map(|s| s.role).collect();
        assert_eq!(hidden, [SpanRole::Delimiter, SpanRole::Delimiter, SpanRole::Ref]);
    }
}
