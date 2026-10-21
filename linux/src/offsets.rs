//! The document's source text, mirrored beside the GtkTextBuffer, and the
//! mapping between the two coordinate systems.
//!
//! - **Source offsets** are UTF-8 byte offsets into the file. `layout`,
//!   `edit_rules` and `review` use only these.
//! - **Buffer offsets** are GTK character offsets. They count Unicode scalars
//!   plus one U+FFFC per child anchor (a table grid, an image).
//!
//! An anchor sits just before the source offset it is attached to, so buffer
//! offsets `p` (the anchor) and `p + 1` both map to that source offset. The
//! buffer's hidden-inclusive text leaves anchors out, so it always equals
//! `text`, and saving needs no mapping.
//!
//! Lookups binary-search (byte, char) checkpoints spaced about `STEP` bytes
//! apart, then count characters in the gap, so each costs O(log n + STEP).
//! Edits shift the checkpoints after them and re-space the edited gap.

use std::ops::Range;

const STEP: usize = 256;

#[derive(Clone, Debug)]
pub struct SourceText {
    text: String,
    /// (byte, char) pairs, ascending, starting with (0, 0); every byte is a
    /// character boundary.
    points: Vec<(usize, usize)>,
    /// Source offsets of the anchors, ascending.
    anchors: Vec<usize>,
}

fn char_count(s: &str) -> usize {
    s.bytes().filter(|b| b & 0xC0 != 0x80).count()
}

impl SourceText {
    pub fn new(text: String) -> SourceText {
        let mut source = SourceText { text, points: Vec::new(), anchors: Vec::new() };
        source.points = source.checkpoints(0, 0, source.text.len());
        source
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn anchors(&self) -> &[usize] {
        &self.anchors
    }

    /// Checkpoints from `(byte, chars)` up to (not including) `end`.
    fn checkpoints(&self, mut byte: usize, mut chars: usize, end: usize) -> Vec<(usize, usize)> {
        let mut out = vec![(byte, chars)];
        let bytes = self.text.as_bytes();
        while byte + STEP < end {
            let mut next = byte + STEP;
            while !self.text.is_char_boundary(next) {
                next += 1;
            }
            chars += bytes[byte..next].iter().filter(|b| *b & 0xC0 != 0x80).count();
            byte = next;
            out.push((byte, chars));
        }
        out
    }

    /// Characters before source byte `byte` (a character boundary).
    pub fn chars_before(&self, byte: usize) -> usize {
        let i = self.points.partition_point(|&(b, _)| b <= byte) - 1;
        let (b, c) = self.points[i];
        c + char_count(&self.text[b..byte])
    }

    /// The source byte offset of character `chars`.
    fn byte_of_char(&self, chars: usize) -> usize {
        let i = self.points.partition_point(|&(_, c)| c <= chars) - 1;
        let (b, c) = self.points[i];
        self.text[b..].char_indices().nth(chars - c).map_or(self.text.len(), |(i, _)| b + i)
    }

    /// Buffer offset of source offset `byte`: past any anchor attached there.
    pub fn to_buffer(&self, byte: usize) -> i32 {
        let anchors = self.anchors.partition_point(|&a| a <= byte);
        (self.chars_before(byte) + anchors) as i32
    }

    /// Buffer offset of the anchor at index `k`.
    fn anchor_position(&self, k: usize) -> usize {
        self.chars_before(self.anchors[k]) + k
    }

    /// Anchors that sit before buffer offset `offset`.
    fn anchors_before(&self, offset: usize) -> usize {
        let (mut lo, mut hi) = (0, self.anchors.len());
        while lo < hi {
            let mid = (lo + hi) / 2;
            if self.anchor_position(mid) < offset { lo = mid + 1 } else { hi = mid }
        }
        lo
    }

    /// Source offset of buffer offset `offset`. An anchor maps to the source
    /// offset it is attached to.
    pub fn to_source(&self, offset: i32) -> usize {
        let offset = offset.max(0) as usize;
        let chars = offset - self.anchors_before(offset);
        self.byte_of_char(chars)
    }

    /// Whether buffer offset `offset` is an anchor's character.
    pub fn is_anchor(&self, offset: i32) -> bool {
        let k = self.anchors_before(offset.max(0) as usize);
        k < self.anchors.len() && self.anchor_position(k) == offset as usize
    }

    /// Record an anchor inserted into the buffer before source offset `byte`.
    pub fn add_anchor(&mut self, byte: usize) {
        let i = self.anchors.partition_point(|&a| a < byte);
        self.anchors.insert(i, byte);
    }

    /// Forget the anchor before source offset `byte` (one the view removed
    /// from the buffer itself). Whether there was one.
    pub fn remove_anchor(&mut self, byte: usize) -> bool {
        match self.anchors.binary_search(&byte) {
            Ok(i) => {
                self.anchors.remove(i);
                true
            }
            Err(_) => false,
        }
    }

    /// Mirror text inserted at buffer offset `offset`. Returns the source offset.
    pub fn insert(&mut self, offset: i32, inserted: &str) -> usize {
        let anchors_before = self.anchors_before(offset.max(0) as usize);
        let at = self.to_source(offset);
        let (bytes, chars) = (inserted.len(), char_count(inserted));
        self.text.insert_str(at, inserted);
        for anchor in &mut self.anchors[anchors_before..] {
            *anchor += bytes;
        }
        let first_after = self.points.partition_point(|&(b, _)| b <= at);
        for point in &mut self.points[first_after..] {
            point.0 += bytes;
            point.1 += chars;
        }
        self.respace(at, at + bytes);
        at
    }

    /// Mirror a buffer deletion of `range` (buffer offsets). Returns the source
    /// range removed and how many anchors went with it.
    pub fn delete(&mut self, range: Range<i32>) -> (Range<usize>, usize) {
        let (start, end) = (range.start.max(0) as usize, range.end.max(0) as usize);
        let first = self.anchors_before(start);
        let last = self.anchors_before(end);
        let source = self.to_source(start as i32)..self.to_source(end as i32);
        let (bytes, chars) = (source.len(), char_count(&self.text[source.clone()]));
        self.anchors.drain(first..last);
        for anchor in &mut self.anchors[first..] {
            *anchor -= bytes;
        }
        self.text.replace_range(source.clone(), "");
        self.points.retain(|&(b, _)| b <= source.start || b >= source.end);
        let first_after = self.points.partition_point(|&(b, _)| b <= source.start);
        for point in &mut self.points[first_after..] {
            point.0 -= bytes;
            point.1 -= chars;
        }
        self.points.dedup_by_key(|p| p.0);
        self.respace(source.start, source.start);
        (source, last - first)
    }

    /// Re-space the checkpoints of the gap containing `start..end`.
    fn respace(&mut self, start: usize, end: usize) {
        let lo = self.points.partition_point(|&(b, _)| b <= start) - 1;
        let hi = self.points.partition_point(|&(b, _)| b <= end);
        let gap_end = self.points.get(hi).map_or(self.text.len(), |p| p.0);
        let (b, c) = self.points[lo];
        if gap_end - b <= 2 * STEP {
            return;
        }
        let fresh = self.checkpoints(b, c, gap_end);
        self.points.splice(lo..hi, fresh);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The buffer as GTK holds it: anchors as U+FFFC.
    fn buffer(source: &SourceText) -> Vec<char> {
        let mut out = Vec::new();
        for (i, c) in source.text().char_indices().chain(std::iter::once((source.text().len(), '\0'))) {
            let anchors = source.anchors().iter().filter(|&&a| a == i).count();
            out.extend(std::iter::repeat_n('\u{FFFC}', anchors));
            if c != '\0' {
                out.push(c);
            }
        }
        out
    }

    fn check(source: &SourceText) {
        let chars = buffer(source);
        let mut expected_source = 0;
        for (offset, c) in chars.iter().enumerate() {
            assert_eq!(source.to_source(offset as i32), expected_source, "offset {offset}");
            assert_eq!(source.is_anchor(offset as i32), *c == '\u{FFFC}', "offset {offset}");
            if *c != '\u{FFFC}' {
                assert_eq!(source.to_buffer(expected_source), offset as i32, "source {expected_source}");
                expected_source += c.len_utf8();
            }
        }
        assert_eq!(source.to_source(chars.len() as i32), source.text().len());
        let rebuilt = SourceText::new(source.text().to_string());
        for byte in (0..=source.text().len()).filter(|&b| source.text().is_char_boundary(b)) {
            assert_eq!(source.chars_before(byte), rebuilt.chars_before(byte), "checkpoints drifted at {byte}");
        }
    }

    #[test]
    fn maps_both_ways_around_anchors_and_multibyte_text() {
        let mut source = SourceText::new("é😀 a\n| t |\nb".repeat(100));
        source.add_anchor(8);
        source.add_anchor(16 * 50 + 8);
        check(&source);
        // An anchor sits before its source offset: both map to it.
        // "é😀 a\n": byte 8 is the newline, character 4.
        assert_eq!(source.to_source(4), 8);
        assert_eq!(source.to_source(5), 8);
        assert!(source.is_anchor(4));
        assert_eq!(source.to_buffer(8), 5);
        // Removing one the view put there.
        assert!(source.remove_anchor(8));
        assert!(!source.remove_anchor(8));
        assert_eq!(source.to_buffer(8), 4);
        check(&source);
    }

    #[test]
    fn edits_keep_text_anchors_and_checkpoints_in_step() {
        let mut source = SourceText::new("abc 日本 😀 ".repeat(300));
        source.add_anchor(100);
        source.add_anchor(2000);
        let mut model = source.text().to_string();
        // Typing just after an anchor leaves it in place.
        let after = source.to_buffer(100);
        assert_eq!(source.insert(after, "xy"), 100);
        model.insert_str(100, "xy");
        assert_eq!(source.anchors(), [100, 2002]);
        // Typing just before it moves it.
        assert_eq!(source.insert(after - 1, "é"), 100);
        model.insert(100, 'é');
        assert_eq!(source.anchors(), [102, 2004]);
        assert_eq!(source.text(), model);
        // A long paste re-spaces its gap.
        let at = source.insert(10, &"😀".repeat(500));
        model.insert_str(at, &"😀".repeat(500));
        assert_eq!(source.text(), model);
        check(&source);
        // A deletion across an anchor removes it.
        let a = source.to_buffer(source.anchors()[0]) - 1;
        let (removed, anchors) = source.delete(a - 3..a + 5);
        model.replace_range(removed, "");
        assert_eq!(source.text(), model);
        assert_eq!(anchors, 1);
        assert_eq!(source.anchors().len(), 1);
        check(&source);
        // Deleting everything.
        let end = buffer(&source).len() as i32;
        source.delete(0..end);
        assert_eq!(source.text(), "");
        assert!(source.anchors().is_empty());
        check(&source);
    }

    #[test]
    fn random_edits_match_a_rebuilt_map() {
        let mut state = 7u64;
        let mut next = |bound: usize| {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((state >> 33) % bound.max(1) as u64) as usize
        };
        let long = "x".repeat(700);
        let mut source = SourceText::new("Some *text* é 😀\n".repeat(80));
        for step in 0..400 {
            let len = buffer(&source).len();
            match next(4) {
                0 => {
                    let at = source.to_source(next(len + 1) as i32);
                    source.add_anchor(at);
                }
                1 => {
                    let start = next(len + 1);
                    let end = (start + next(40)).min(len);
                    source.delete(start as i32..end as i32);
                }
                _ => {
                    let text = ["a", "日本", "😀😀", "\n", &long][next(5)];
                    source.insert(next(len + 1) as i32, text);
                }
            }
            if step % 50 == 0 {
                check(&source);
            }
        }
        check(&source);
    }
}
