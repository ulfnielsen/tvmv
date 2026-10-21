//! Caret and delete behavior around hidden markup, as pure functions of the
//! text and a hidden-character predicate. `is_hidden(i)` is true when the
//! byte at offset `i` belongs to currently hidden markup.
//!
//! A port of `Sources/TVMVCore/EditRules.swift`, in UTF-8 byte offsets. GTK
//! already skips invisible text for arrow keys, word motion and selection, so
//! the view needs `snap_caret` only for the line-prefix and collapsed-line
//! cases; the rules themselves are kept whole so the two stay comparable.

use std::ops::Range;

use unicode_segmentation::GraphemeCursor;

/// One replacement in the source: `range` becomes `insert`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Edit {
    pub range: Range<usize>,
    pub insert: String,
}

/// The maximal run of hidden bytes containing offset `i`.
pub fn hidden_run(i: usize, length: usize, is_hidden: impl Fn(usize) -> bool) -> Range<usize> {
    let (mut start, mut end) = (i, i);
    while start > 0 && is_hidden(start - 1) {
        start -= 1;
    }
    while end < length && is_hidden(end) {
        end += 1;
    }
    start..end
}

fn is_line_start(i: usize, text: &str) -> bool {
    i == 0 || text.as_bytes()[i - 1] == b'\n'
}

/// Where a zero-length caret requested at `location` should rest.
///
/// - Inside a hidden run: pass over it in the direction of travel.
/// - A run that begins a line (a heading's "# "): always rest after it, so
///   typing at a line's visual start stays inside the heading.
/// - A run that is a whole collapsed line (code fence, setext underline):
///   moving forward lands after it; moving back lands at the end of the
///   previous line.
pub fn snap_caret(location: usize, moving_forward: bool, text: &str, is_hidden: impl Fn(usize) -> bool) -> usize {
    let length = text.len();
    let inside_run = location > 0 && location < length && is_hidden(location - 1) && is_hidden(location);
    let before_line_prefix = location < length && is_hidden(location) && is_line_start(location, text);
    if !(inside_run || before_line_prefix) {
        return location;
    }
    let run = hidden_run(location, length, &is_hidden);
    let whole_line = is_line_start(run.start, text) && run.end > run.start && text.as_bytes()[run.end - 1] == b'\n';
    if whole_line {
        if moving_forward || run.start == 0 {
            return run.end;
        }
        return run.start - 1;
    }
    if is_line_start(run.start, text) {
        return run.end;
    }
    if moving_forward { run.end } else { run.start }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeleteAction {
    /// Let the text view delete as requested.
    Allow,
    /// Delete this range instead.
    Replace(Range<usize>),
    /// Do nothing.
    Ignore,
}

/// The grapheme cluster containing byte `i`: an emoji, flag or combining
/// sequence spans several characters, and deleting one would corrupt it.
fn cluster_at(text: &str, mut i: usize) -> Range<usize> {
    while !text.is_char_boundary(i) {
        i -= 1;
    }
    let mut cursor = GraphemeCursor::new(i, text.len(), true);
    let start = match cursor.is_boundary(text, 0) {
        Ok(true) => i,
        _ => cursor.prev_boundary(text, 0).ok().flatten().unwrap_or(i),
    };
    let mut cursor = GraphemeCursor::new(start, text.len(), true);
    let end = cursor.next_boundary(text, 0).ok().flatten().unwrap_or(text.len());
    start..end
}

/// A one-character delete that lands on hidden markup. `range` is the
/// character the view was about to delete; `caret` is where the caret sits.
///
/// - Backspace right after a hidden line prefix ("# ") removes the prefix.
/// - Backspace or forward-delete into a collapsed line does nothing (it would
///   join a code block to its neighbor).
/// - Otherwise the nearest visible character in that direction goes.
pub fn retarget_delete(range: Range<usize>, caret: usize, text: &str, is_hidden: impl Fn(usize) -> bool) -> DeleteAction {
    let one_char = text.get(range.clone()).is_some_and(|s| s.chars().count() == 1);
    if !one_char || !is_hidden(range.start) {
        return DeleteAction::Allow;
    }
    let length = text.len();
    let run = hidden_run(range.start, length, &is_hidden);
    let backward = caret == range.end;
    let whole_line = is_line_start(run.start, text) && text.as_bytes()[run.end - 1] == b'\n';
    if whole_line {
        return DeleteAction::Ignore;
    }
    if backward && is_line_start(run.start, text) {
        return DeleteAction::Replace(run);
    }
    let mut target = if backward { run.start as isize - 1 } else { run.end as isize };
    while target >= 0 && (target as usize) < length && is_hidden(target as usize) {
        target += if backward { -1 } else { 1 };
    }
    if target < 0 || target as usize >= length {
        return DeleteAction::Ignore;
    }
    DeleteAction::Replace(cluster_at(text, target as usize))
}

/// Wrap a non-empty selection in `marker` (or unwrap it if it already is
/// wrapped). Returns the edits (ascending, against the current text) and the
/// selection afterwards; None when there is nothing to do.
pub fn toggle_wrap(selection: Range<usize>, marker: &str, text: &str) -> Option<(Vec<Edit>, Range<usize>)> {
    if selection.is_empty() {
        return None;
    }
    let k = marker.len();
    let edit = |range: Range<usize>, insert: &str| Edit { range, insert: insert.to_string() };
    let wrapped = selection.start >= k
        && selection.end + k <= text.len()
        && text.get(selection.start - k..selection.start) == Some(marker)
        && text.get(selection.end..selection.end + k) == Some(marker);
    if wrapped {
        return Some((
            vec![edit(selection.start - k..selection.start, ""), edit(selection.end..selection.end + k, "")],
            selection.start - k..selection.end - k,
        ));
    }
    Some((
        vec![edit(selection.start..selection.start, marker), edit(selection.end..selection.end, marker)],
        selection.start + k..selection.end + k,
    ))
}

#[cfg(test)]
mod tests {
    //! Mirrors `Tests/TVMVCoreTests/EditRulesTests.swift`.
    use super::*;
    use crate::layout::parse;

    const TEXT: &str = "# Title\n\nSome *em* text\n\n```\ncode\n```\nafter\n";

    fn hidden_set(text: &str) -> Vec<bool> {
        let mut hidden = vec![false; text.len()];
        for marker in parse(text).markers {
            hidden[marker.range].iter_mut().for_each(|h| *h = true);
        }
        hidden
    }

    fn snap(location: usize, forward: bool) -> usize {
        let hidden = hidden_set(TEXT);
        snap_caret(location, forward, TEXT, |i| hidden[i])
    }

    fn delete(location: usize, caret: usize) -> DeleteAction {
        let hidden = hidden_set(TEXT);
        let end = location + TEXT[location..].chars().next().unwrap().len_utf8();
        retarget_delete(location..end, caret, TEXT, |i| hidden[i])
    }

    fn find(needle: &str) -> Range<usize> {
        let start = TEXT.find(needle).unwrap();
        start..start + needle.len()
    }

    #[test]
    fn caret_never_rests_before_a_hidden_heading_prefix() {
        assert_eq!(snap(0, true), 2);
        assert_eq!(snap(0, false), 2);
        assert_eq!(snap(1, false), 2);
    }

    #[test]
    fn caret_may_rest_at_the_inner_edge_of_formatting() {
        let em = find("*em*");
        assert_eq!(snap(em.start + 1, true), em.start + 1);
        assert_eq!(snap(em.end - 1, true), em.end - 1);
    }

    #[test]
    fn collapsed_fence_lines_are_passed_in_the_direction_of_travel() {
        let fence = find("```\ncode").start;
        let close = find("```\nafter").start;
        assert_eq!(snap(fence, true), fence + 4);
        assert_eq!(snap(fence + 2, false), fence - 1);
        assert_eq!(snap(close, true), close + 4);
    }

    #[test]
    fn backspace_after_a_heading_prefix_removes_the_prefix() {
        assert_eq!(delete(1, 2), DeleteAction::Replace(0..2));
    }

    #[test]
    fn deleting_hidden_markup_deletes_the_nearest_visible_character() {
        let em = find("*em*");
        assert_eq!(delete(em.end - 1, em.end), DeleteAction::Replace(em.end - 2..em.end - 1));
        assert_eq!(delete(em.start, em.start), DeleteAction::Replace(em.start + 1..em.start + 2));
    }

    #[test]
    fn backspace_into_a_collapsed_fence_does_nothing() {
        let code = find("code").start;
        assert_eq!(delete(code - 1, code), DeleteAction::Ignore);
    }

    #[test]
    fn visible_deletes_are_untouched() {
        assert_eq!(delete(10, 11), DeleteAction::Allow);
    }

    #[test]
    fn toggle_wrap_wraps_and_unwraps() {
        let (edits, selection) = toggle_wrap(9..13, "*", TEXT).unwrap();
        assert_eq!(edits, [Edit { range: 9..9, insert: "*".into() }, Edit { range: 13..13, insert: "*".into() }]);
        assert_eq!(selection, 10..14);

        let em = find("em");
        let (edits, selection) = toggle_wrap(em.clone(), "*", TEXT).unwrap();
        assert_eq!(
            edits,
            [Edit { range: em.start - 1..em.start, insert: "".into() }, Edit { range: em.end..em.end + 1, insert: "".into() }]
        );
        assert_eq!(selection, em.start - 1..em.end - 1);

        assert_eq!(toggle_wrap(3..3, "*", TEXT), None);
    }

    #[test]
    fn deletes_never_split_a_character_beside_hidden_markup() {
        // A retargeted delete that removes part of an emoji corrupts the file.
        let emoji = "😀*a*😀\n";
        let hidden = hidden_set(emoji);
        // Backspace with the caret just after the opening (hidden) "*".
        assert_eq!(retarget_delete(4..5, 5, emoji, |i| hidden[i]), DeleteAction::Replace(0..4));
        // Forward delete onto the closing (hidden) "*".
        assert_eq!(retarget_delete(6..7, 6, emoji, |i| hidden[i]), DeleteAction::Replace(7..11));
        // A flag is one cluster of two characters.
        let flag = "🇩🇰*a*\n";
        let hidden = hidden_set(flag);
        assert_eq!(retarget_delete(8..9, 9, flag, |i| hidden[i]), DeleteAction::Replace(0..8));
    }
}
