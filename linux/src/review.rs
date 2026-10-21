//! Review comments and suggested edits, stored in the Markdown file itself.
//! A port of `Sources/TVMVCore/ReviewMarkup.swift` and
//! `ReviewRendering.swift`; any change here needs the matching change there.
//!
//! CriticMarkup anchors mark *what* a thread is about and a GFM footnote holds
//! the thread:
//!
//! ```text
//! The {==cache==}[^rv-k3f9] is {~~lazy~>eager~~}[^rv-p2x7].
//!
//! [^rv-k3f9]: @ulf 2026-10-14: True for autosave too?
//!     @claude 2026-10-14: No.
//! [^rv-p2x7]: @claude 2026-10-14 suggestion: Avoids the stall.
//! ```
//!
//! Only `rv-` footnotes belong to review; every other footnote is left alone.
//! Ranges are UTF-8 byte offsets (the Swift side counts UTF-16). Every
//! delimiter is ASCII, so the two scanners see the same anchors and every
//! range falls on a char boundary.
//!
//! Parsing never fails: a hand-edited file degrades into `problems`.

use std::collections::HashSet;
use std::ops::Range;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnchorKind {
    Highlight,
    Insertion,
    Deletion,
    Substitution,
    Point,
}

impl AnchorKind {
    /// Insertions, deletions and substitutions are accepted or rejected;
    /// highlights and points are resolved.
    pub fn is_suggestion(self) -> bool {
        matches!(self, Self::Insertion | Self::Deletion | Self::Substitution)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Anchor {
    pub id: String,
    pub kind: AnchorKind,
    /// Everything from the opening delimiter through the `[^id]` ref.
    pub range: Range<usize>,
    /// The text between the delimiters (`old~>new` for a substitution);
    /// empty, at the ref, for a point comment.
    pub inner: Range<usize>,
    /// Substitution only: the two sides of `~>`.
    pub old: Option<Range<usize>>,
    pub new: Option<Range<usize>>,
    /// The `[^id]` ref. For a point comment this is the whole anchor.
    pub reference: Range<usize>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryKind {
    Comment,
    Suggestion,
}

/// One `@author YYYY-MM-DD[ suggestion]: text` line of a thread, plus any
/// continuation lines that are not entries themselves.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    /// Without the leading `@`; empty when the line is not in entry form.
    pub author: String,
    /// `YYYY-MM-DD` as written; empty when the line is not in entry form.
    pub date: String,
    pub kind: EntryKind,
    /// Continuation lines join with "\n", their indent stripped.
    pub body: String,
    pub range: Range<usize>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Thread {
    pub id: String,
    /// The whole definition block, including its final newline if any.
    pub range: Range<usize>,
    pub entries: Vec<Entry>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Problem {
    /// A thread definition no anchor refers to.
    OrphanThread { id: String, range: Range<usize> },
    /// An anchor whose id has no thread definition.
    DanglingAnchor { id: String, range: Range<usize> },
    /// An opening delimiter with no closer in its block, or a stray closer.
    Unbalanced { range: Range<usize> },
    /// Anchors under one id mix comment kinds and suggestion kinds.
    MixedKinds { id: String },
    /// A second definition for an id; Markdown readers show the first.
    DuplicateThread { id: String, range: Range<usize> },
    /// A thread line that is not `@author YYYY-MM-DD[ suggestion]: text`.
    MalformedEntry { id: String, range: Range<usize> },
}

/// Everything review-related in one document.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Review {
    pub anchors: Vec<Anchor>,
    pub threads: Vec<Thread>,
    pub problems: Vec<Problem>,
    /// Fenced code and `$$` math blocks, from the opening line through the
    /// closing one: markup inside is literal text.
    pub literal_blocks: Vec<Range<usize>>,
    /// Inline code spans outside anchors, backticks included.
    pub literal_spans: Vec<Range<usize>>,
}

pub fn parse(text: &str) -> Review {
    let mut parser = Parser::new(text);
    parser.run();
    let mut problems = parser.problems;
    problems.extend(cross_check(&parser.anchors, &parser.threads));
    Review {
        anchors: parser.anchors,
        threads: parser.threads,
        problems,
        literal_blocks: parser.literal_blocks,
        literal_spans: parser.literal_spans,
    }
}

/// Problems that need the whole document: orphans, dangling refs, mixed kinds.
fn cross_check(anchors: &[Anchor], threads: &[Thread]) -> Vec<Problem> {
    let mut problems = Vec::new();
    let anchored: HashSet<&str> = anchors.iter().map(|a| a.id.as_str()).collect();
    let defined: HashSet<&str> = threads.iter().map(|t| t.id.as_str()).collect();
    for thread in threads.iter().filter(|t| !anchored.contains(t.id.as_str())) {
        problems.push(Problem::OrphanThread { id: thread.id.clone(), range: thread.range.clone() });
    }
    for anchor in anchors.iter().filter(|a| !defined.contains(a.id.as_str())) {
        problems.push(Problem::DanglingAnchor { id: anchor.id.clone(), range: anchor.range.clone() });
    }
    let mut seen = HashSet::new();
    for anchor in anchors {
        if !seen.insert(anchor.id.as_str()) {
            continue;
        }
        let kinds: HashSet<bool> = anchors
            .iter()
            .filter(|a| a.id == anchor.id)
            .map(|a| a.kind.is_suggestion())
            .collect();
        if kinds.len() > 1 {
            problems.push(Problem::MixedKinds { id: anchor.id.clone() });
        }
    }
    problems
}

// MARK: Scanner

fn is_blank(c: u8) -> bool {
    c == b' ' || c == b'\t'
}

fn is_id_char(c: u8) -> bool {
    c.is_ascii_digit() || c.is_ascii_lowercase()
}

struct Parser<'a> {
    text: &'a str,
    u: &'a [u8],
    anchors: Vec<Anchor>,
    threads: Vec<Thread>,
    problems: Vec<Problem>,
    literal_blocks: Vec<Range<usize>>,
    literal_spans: Vec<Range<usize>>,
    /// Lines as byte ranges, each excluding its "\n".
    lines: Vec<Range<usize>>,
}

impl<'a> Parser<'a> {
    fn new(text: &'a str) -> Self {
        let u = text.as_bytes();
        let mut lines = Vec::new();
        let mut start = 0;
        for (index, &unit) in u.iter().enumerate() {
            if unit == b'\n' {
                lines.push(start..index);
                start = index + 1;
            }
        }
        if start < u.len() {
            lines.push(start..u.len());
        }
        Parser {
            text,
            u,
            anchors: Vec::new(),
            threads: Vec::new(),
            problems: Vec::new(),
            literal_blocks: Vec::new(),
            literal_spans: Vec::new(),
            lines,
        }
    }

    fn string(&self, range: Range<usize>) -> String {
        self.text[range].to_string()
    }

    // MARK: Blocks

    /// Walk the lines, setting aside code fences, math blocks and thread
    /// definitions, and scan each remaining run of non-blank lines (a block,
    /// as far as CriticMarkup is concerned) for anchors.
    fn run(&mut self) {
        let mut index = 0;
        let mut block: Option<Range<usize>> = None;

        while index < self.lines.len() {
            let line = self.lines[index].clone();
            if let Some(fence) = self.fence_opener(&line) {
                if let Some(range) = block.take() {
                    self.scan_inline(range);
                }
                index += 1;
                while index < self.lines.len() && !self.is_fence_closer(&self.lines[index], fence) {
                    index += 1;
                }
                let last = &self.lines[index.min(self.lines.len() - 1)];
                self.literal_blocks.push(line.start..last.end);
                index += 1;
            } else if let Some(after_open) = self.math_opener(&line) {
                if let Some(range) = block.take() {
                    self.scan_inline(range);
                }
                if !self.contains_pair(b'$', b'$', after_open..line.end) {
                    index += 1;
                    while index < self.lines.len()
                        && !self.contains_pair(b'$', b'$', self.lines[index].clone())
                    {
                        index += 1;
                    }
                }
                let last = &self.lines[index.min(self.lines.len() - 1)];
                self.literal_blocks.push(line.start..last.end);
                index += 1;
            } else if let Some((id, after_colon)) = self.definition_label(&line) {
                if let Some(range) = block.take() {
                    self.scan_inline(range);
                }
                index = self.parse_thread(id, index, after_colon);
            } else if self.u[line.clone()].iter().all(|&c| is_blank(c)) {
                if let Some(range) = block.take() {
                    self.scan_inline(range);
                }
                index += 1;
            } else {
                let start = block.as_ref().map_or(line.start, |b| b.start);
                block = Some(start..line.end);
                index += 1;
            }
        }
        if let Some(range) = block.take() {
            self.scan_inline(range);
        }
    }

    /// Container prefixes (indentation, `>` quotes, one list marker) that may
    /// precede a fence or `$$` inside a quote or list item.
    fn skip_container_prefix(&self, line: &Range<usize>) -> usize {
        let u = self.u;
        let mut p = line.start;
        while p < line.end && (is_blank(u[p]) || u[p] == b'>') {
            p += 1;
        }
        if p + 1 < line.end && matches!(u[p], b'-' | b'*' | b'+') && is_blank(u[p + 1]) {
            p += 2;
        } else {
            let mut q = p;
            while q < line.end && u[q].is_ascii_digit() {
                q += 1;
            }
            if q > p && q + 1 < line.end && (u[q] == b'.' || u[q] == b')') && is_blank(u[q + 1]) {
                p = q + 2;
            }
        }
        while p < line.end && is_blank(u[p]) {
            p += 1;
        }
        p
    }

    fn run_of(&self, unit: u8, start: usize, limit: usize) -> usize {
        let mut p = start;
        while p < limit && self.u[p] == unit {
            p += 1;
        }
        p - start
    }

    fn fence_opener(&self, line: &Range<usize>) -> Option<(u8, usize)> {
        let u = self.u;
        let p = self.skip_container_prefix(line);
        if p >= line.end || (u[p] != b'`' && u[p] != b'~') {
            return None;
        }
        let count = self.run_of(u[p], p, line.end);
        if count < 3 {
            return None;
        }
        // A backtick fence's info string cannot contain a backtick.
        if u[p] == b'`' && u[p + count..line.end].contains(&b'`') {
            return None;
        }
        Some((u[p], count))
    }

    fn is_fence_closer(&self, line: &Range<usize>, (unit, fence_count): (u8, usize)) -> bool {
        let u = self.u;
        let mut p = line.start;
        while p < line.end && (is_blank(u[p]) || u[p] == b'>') {
            p += 1;
        }
        let count = self.run_of(unit, p, line.end);
        count >= fence_count && u[p + count..line.end].iter().all(|&c| is_blank(c))
    }

    /// The offset after an opening `$$`, if the line starts a math block.
    fn math_opener(&self, line: &Range<usize>) -> Option<usize> {
        let u = self.u;
        let mut p = line.start;
        while p < line.end && (is_blank(u[p]) || u[p] == b'>') {
            p += 1;
        }
        (p + 1 < line.end && u[p] == b'$' && u[p + 1] == b'$').then_some(p + 2)
    }

    fn contains_pair(&self, a: u8, b: u8, range: Range<usize>) -> bool {
        self.u[range].windows(2).any(|w| w[0] == a && w[1] == b)
    }

    // MARK: Threads

    /// `[^rv-xxxx]:` at the start of a line (up to three spaces of indent).
    fn definition_label(&self, line: &Range<usize>) -> Option<(String, usize)> {
        let mut p = line.start;
        while p < line.end && p - line.start < 3 && self.u[p] == b' ' {
            p += 1;
        }
        let (id, end) = self.reference(p, line.end)?;
        (end < line.end && self.u[end] == b':').then_some((id, end + 1))
    }

    /// Consume a definition block: the label line, then indented lines and
    /// unindented entry lines up to the first blank line. Returns the index of
    /// the first line after the block.
    fn parse_thread(&mut self, id: String, first_line: usize, after_colon: usize) -> usize {
        let u = self.u;
        let mut entries: Vec<Entry> = Vec::new();
        let mut malformed: Vec<Range<usize>> = Vec::new();

        let add = |parser: &Parser, entries: &mut Vec<Entry>, malformed: &mut Vec<Range<usize>>,
                   content: Range<usize>, entry_range: Range<usize>| {
            if let Some(entry) = parser.entry(content.clone(), entry_range.clone()) {
                entries.push(entry);
            } else {
                entries.push(Entry {
                    author: String::new(),
                    date: String::new(),
                    kind: EntryKind::Comment,
                    body: parser.string(parser.trimmed(content)),
                    range: entry_range.clone(),
                });
                malformed.push(entry_range);
            }
        };

        let first = self.lines[first_line].clone();
        let mut p = after_colon;
        while p < first.end && is_blank(u[p]) {
            p += 1;
        }
        add(self, &mut entries, &mut malformed, p..first.end, p..first.end);

        let mut index = first_line + 1;
        while index < self.lines.len() {
            let line = self.lines[index].clone();
            let mut content = line.start;
            while content < line.end && is_blank(u[content]) {
                content += 1;
            }
            if content >= line.end {
                break; // blank line ends it
            }
            let indented = u[line.start] == b'\t' || content - line.start >= 4;
            if self.entry(content..line.end, line.clone()).is_some() {
                add(self, &mut entries, &mut malformed, content..line.end, line.clone());
            } else if indented && !entries.is_empty() {
                // A continuation of the previous entry's body.
                let piece = self.string(self.trimmed(content..line.end));
                let last = entries.last_mut().expect("entries is not empty");
                if !last.body.is_empty() {
                    last.body.push('\n');
                }
                last.body.push_str(&piece);
                last.range = last.range.start..line.end;
            } else {
                break;
            }
            index += 1;
        }

        let last_line = &self.lines[index - 1];
        let end = if last_line.end < u.len() { last_line.end + 1 } else { last_line.end };
        let range = first.start..end;
        if self.threads.iter().any(|t| t.id == id) {
            self.problems.push(Problem::DuplicateThread { id: id.clone(), range: range.clone() });
        }
        self.problems.extend(
            malformed.into_iter().map(|range| Problem::MalformedEntry { id: id.clone(), range }),
        );
        self.threads.push(Thread { id, range, entries });
        index
    }

    fn trimmed(&self, range: Range<usize>) -> Range<usize> {
        let (mut lower, mut upper) = (range.start, range.end);
        while lower < upper && is_blank(self.u[lower]) {
            lower += 1;
        }
        while upper > lower && is_blank(self.u[upper - 1]) {
            upper -= 1;
        }
        lower..upper
    }

    /// `@author YYYY-MM-DD[ suggestion]:[ body]`, or None.
    fn entry(&self, content: Range<usize>, range: Range<usize>) -> Option<Entry> {
        let u = self.u;
        let end = content.end;
        let mut p = content.start;
        if p >= end || u[p] != b'@' {
            return None;
        }
        p += 1;
        let author_start = p;
        while p < end && !is_blank(u[p]) {
            p += 1;
        }
        if p == author_start || p >= end || u[p] != b' ' {
            return None;
        }
        let author = author_start..p;
        p += 1;

        // YYYY-MM-DD
        let date_start = p;
        for expect_digit in [true, true, true, true, false, true, true, false, true, true] {
            if p >= end {
                return None;
            }
            let ok = if expect_digit { u[p].is_ascii_digit() } else { u[p] == b'-' };
            if !ok {
                return None;
            }
            p += 1;
        }
        let date = date_start..p;

        let mut kind = EntryKind::Comment;
        let marker = b" suggestion";
        if u[p..end].starts_with(marker) {
            kind = EntryKind::Suggestion;
            p += marker.len();
        }
        if p >= end || u[p] != b':' {
            return None;
        }
        p += 1;
        Some(Entry {
            author: self.string(author),
            date: self.string(date),
            kind,
            body: self.string(self.trimmed(p..end)),
            range,
        })
    }

    // MARK: Inline

    /// `[^rv-xxxx]` starting at `p`: the id and the offset after `]`.
    fn reference(&self, p: usize, limit: usize) -> Option<(String, usize)> {
        let prefix = b"[^rv-";
        if p + prefix.len() >= limit || &self.u[p..p + prefix.len()] != prefix {
            return None;
        }
        let mut q = p + prefix.len();
        while q < limit && is_id_char(self.u[q]) {
            q += 1;
        }
        if q == p + prefix.len() || q >= limit || self.u[q] != b']' {
            return None;
        }
        Some((self.string(p + 2..q), q + 1))
    }

    fn kind(a: u8, b: u8) -> Option<AnchorKind> {
        if a != b {
            return None;
        }
        match a {
            b'=' => Some(AnchorKind::Highlight),
            b'+' => Some(AnchorKind::Insertion),
            b'-' => Some(AnchorKind::Deletion),
            b'~' => Some(AnchorKind::Substitution),
            _ => None,
        }
    }

    fn delimiter_unit(kind: AnchorKind) -> u8 {
        match kind {
            AnchorKind::Highlight => b'=',
            AnchorKind::Insertion => b'+',
            AnchorKind::Deletion => b'-',
            AnchorKind::Substitution | AnchorKind::Point => b'~',
        }
    }

    fn is_closer(&self, p: usize, limit: usize) -> bool {
        p + 2 < limit && self.u[p + 2] == b'}' && Self::kind(self.u[p], self.u[p + 1]).is_some()
    }

    /// If a code span opens at `p`, the offset after it closes.
    fn code_span_end(&self, p: usize, limit: usize) -> Option<usize> {
        if self.u[p] != b'`' {
            return None;
        }
        let count = self.run_of(b'`', p, limit);
        let mut q = p + count;
        while q < limit {
            if self.u[q] == b'`' {
                let closing = self.run_of(b'`', q, limit);
                if closing == count {
                    return Some(q + closing);
                }
                q += closing;
            } else {
                q += 1;
            }
        }
        None
    }

    /// The offset of the first `xx}` closer for `kind` at or after `start`,
    /// stepping over code spans.
    fn closer(&self, kind: AnchorKind, start: usize, limit: usize) -> Option<usize> {
        let unit = Self::delimiter_unit(kind);
        let mut q = start;
        while q < limit {
            if let Some(after) = self.code_span_end(q, limit) {
                q = after;
                continue;
            }
            if q + 2 < limit && self.u[q] == unit && self.u[q + 1] == unit && self.u[q + 2] == b'}' {
                return Some(q);
            }
            q += 1;
        }
        None
    }

    fn scan_inline(&mut self, block: Range<usize>) {
        let limit = block.end;
        let mut p = block.start;
        while p < limit {
            if self.u[p] == b'`' {
                if let Some(end) = self.code_span_end(p, limit) {
                    self.literal_spans.push(p..end);
                    p = end;
                } else {
                    p += self.run_of(b'`', p, limit);
                }
                continue;
            }
            if self.u[p] == b'{' && p + 2 < limit {
                if let Some(kind) = Self::kind(self.u[p + 1], self.u[p + 2]) {
                    p = self.scan_anchor(kind, p, limit);
                    continue;
                }
            }
            if let Some((id, end)) = self.reference(p, limit) {
                self.anchors.push(Anchor {
                    id,
                    kind: AnchorKind::Point,
                    range: p..end,
                    inner: p..p,
                    old: None,
                    new: None,
                    reference: p..end,
                });
                p = end;
                continue;
            }
            if self.is_closer(p, limit) {
                self.problems.push(Problem::Unbalanced { range: p..p + 3 });
                p += 3;
                continue;
            }
            p += 1;
        }
    }

    /// Scan the anchor opening at `p`; returns where scanning resumes.
    fn scan_anchor(&mut self, kind: AnchorKind, p: usize, limit: usize) -> usize {
        let inner_start = p + 3;
        let Some(close) = self.closer(kind, inner_start, limit) else {
            self.problems.push(Problem::Unbalanced { range: p..inner_start });
            return inner_start;
        };
        let (mut old, mut new) = (None, None);
        if kind == AnchorKind::Substitution {
            let arrow = (inner_start..close)
                .find(|&q| q + 1 < close && self.u[q] == b'~' && self.u[q + 1] == b'>');
            let Some(arrow) = arrow else {
                self.problems.push(Problem::Unbalanced { range: p..inner_start });
                return inner_start;
            };
            old = Some(inner_start..arrow);
            new = Some(arrow + 2..close);
        }
        let after_closer = close + 3;
        // Bare CriticMarkup with no `[^rv-…]` is plain text to review.
        let Some((id, end)) = self.reference(after_closer, limit) else {
            return after_closer;
        };
        self.anchors.push(Anchor {
            id,
            kind,
            range: p..end,
            inner: inner_start..close,
            old,
            new,
            reference: after_closer..end,
        });
        end
    }
}

// MARK: Rendering

// Review markup in rendered HTML. cmark strips raw HTML, so `<mark>`/`<ins>`/
// `<del>` cannot be written into the Markdown before parsing. Instead a
// pre-pass swaps each anchor's delimiters for private-use sentinels, cmark
// renders them as ordinary text, and a post-pass turns them into tags
// carrying `data-rv`. The `[^rv-…]` refs stay in the source, so with
// footnotes on the threads render as GFM footnotes.
//
// Every sentinel has the UTF-8 length of the delimiter it replaces, so lines
// keep their byte lengths and `data-sourcepos` columns match the file as
// written.

// `{==` `==}` `{++` `++}` `{--` `--}` `{~~` → U+E000…U+E006, 3 bytes each.
const HIGHLIGHT_OPEN: char = '\u{E000}';
const HIGHLIGHT_CLOSE: char = '\u{E001}';
const INSERTION_OPEN: char = '\u{E002}';
const INSERTION_CLOSE: char = '\u{E003}';
const DELETION_OPEN: char = '\u{E004}';
const DELETION_CLOSE: char = '\u{E005}';
const SUBSTITUTION_OPEN: char = '\u{E006}';
// `~>` is two bytes and `~~}` three; their sentinels swap those lengths, which
// keeps a one-line substitution's byte count exact.
const SUBSTITUTION_SEPARATOR: char = '\u{E007}';
const SUBSTITUTION_CLOSE: char = '\u{80}';

fn is_sentinel(c: char) -> bool {
    ('\u{E000}'..='\u{E007}').contains(&c) || c == SUBSTITUTION_CLOSE
}

/// The delimiter each sentinel stands for, restored where a tag cannot go.
fn literal(sentinel: char) -> &'static str {
    match sentinel {
        HIGHLIGHT_OPEN => "{==",
        HIGHLIGHT_CLOSE => "==}",
        INSERTION_OPEN => "{++",
        INSERTION_CLOSE => "++}",
        DELETION_OPEN => "{--",
        DELETION_CLOSE => "--}",
        SUBSTITUTION_OPEN => "{~~",
        SUBSTITUTION_SEPARATOR => "~>",
        SUBSTITUTION_CLOSE => "~~}",
        _ => unreachable!("not a sentinel: {sentinel:?}"),
    }
}

fn closer_of(opener: char) -> Option<char> {
    match opener {
        HIGHLIGHT_OPEN => Some(HIGHLIGHT_CLOSE),
        INSERTION_OPEN => Some(INSERTION_CLOSE),
        DELETION_OPEN => Some(DELETION_CLOSE),
        SUBSTITUTION_OPEN => Some(SUBSTITUTION_CLOSE),
        _ => None,
    }
}

/// The Markdown with anchor delimiters swapped for sentinels, or None when
/// review rendering does not apply: no `rv-` refs at all, or a source that
/// already contains a sentinel character and so cannot be decoded safely.
pub fn sentinel_encoded(markdown: &str) -> Option<String> {
    if !markdown.contains("[^rv-") || markdown.chars().any(is_sentinel) {
        return None;
    }

    let review = parse(markdown);
    let mut swaps: Vec<(Range<usize>, char)> = Vec::new();
    for anchor in &review.anchors {
        let opener = anchor.range.start..anchor.inner.start;
        let closer = anchor.inner.end..anchor.reference.start;
        match anchor.kind {
            AnchorKind::Point => {}
            AnchorKind::Highlight => {
                swaps.extend([(opener, HIGHLIGHT_OPEN), (closer, HIGHLIGHT_CLOSE)]);
            }
            AnchorKind::Insertion => {
                swaps.extend([(opener, INSERTION_OPEN), (closer, INSERTION_CLOSE)]);
            }
            AnchorKind::Deletion => {
                swaps.extend([(opener, DELETION_OPEN), (closer, DELETION_CLOSE)]);
            }
            AnchorKind::Substitution => {
                let (Some(old), Some(new)) = (&anchor.old, &anchor.new) else { continue };
                swaps.extend([
                    (opener, SUBSTITUTION_OPEN),
                    (old.end..new.start, SUBSTITUTION_SEPARATOR),
                    (closer, SUBSTITUTION_CLOSE),
                ]);
            }
        }
    }

    let mut result = markdown.to_string();
    for (range, sentinel) in swaps.into_iter().rev() {
        result.replace_range(range, sentinel.encode_utf8(&mut [0; 4]));
    }
    Some(result)
}

/// Turn the sentinels in cmark's HTML into tags, and break `rv-` thread
/// footnotes into one line per entry.
pub fn sentinel_decoded(html: &str) -> String {
    break_thread_entries(&tagged(html))
}

fn tagged(html: &str) -> String {
    // Pieces, with placeholders for opening tags whose id is only known once
    // the closer (and the footnote ref after it) is reached.
    let mut pieces: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut open: Vec<(char, Vec<usize>)> = Vec::new();
    let mut in_tag = false;

    fn placeholder(pieces: &mut Vec<String>, current: &mut String) -> usize {
        pieces.push(std::mem::take(current));
        pieces.push(String::new());
        pieces.len() - 1
    }

    for (index, scalar) in html.char_indices() {
        let next = index + scalar.len_utf8();
        if scalar == '<' {
            in_tag = true;
        } else if scalar == '>' {
            in_tag = false;
        }
        if !is_sentinel(scalar) {
            current.push(scalar);
            continue;
        }
        // Inside an attribute (an image's alt text) a tag cannot go.
        if in_tag {
            current.push_str(literal(scalar));
            continue;
        }

        if closer_of(scalar).is_some() {
            let slot = placeholder(&mut pieces, &mut current);
            open.push((scalar, vec![slot]));
        } else if scalar == SUBSTITUTION_SEPARATOR
            && open.last().is_some_and(|(s, _)| *s == SUBSTITUTION_OPEN)
        {
            let slot = placeholder(&mut pieces, &mut current);
            open.last_mut().expect("checked above").1.push(slot);
        } else if open.last().is_some_and(|(s, _)| closer_of(*s) == Some(scalar)) {
            let (sentinel, slots) = open.pop().expect("checked above");
            let attribute = ref_id(&html[next..])
                .map(|id| format!(" data-rv=\"{id}\""))
                .unwrap_or_default();
            match sentinel {
                HIGHLIGHT_OPEN => {
                    pieces[slots[0]] = format!("<mark{attribute}>");
                    current.push_str("</mark>");
                }
                INSERTION_OPEN => {
                    pieces[slots[0]] = format!("<ins{attribute}>");
                    current.push_str("</ins>");
                }
                DELETION_OPEN => {
                    pieces[slots[0]] = format!("<del{attribute}>");
                    current.push_str("</del>");
                }
                _ => {
                    // substitution
                    if slots.len() != 2 {
                        for &slot in &slots {
                            pieces[slot] = "{~~".into();
                        }
                        current.push_str("~~}");
                    } else {
                        pieces[slots[0]] = format!("<del{attribute}>");
                        pieces[slots[1]] = format!("</del><ins{attribute}>");
                        current.push_str("</ins>");
                    }
                }
            }
        } else {
            current.push_str(literal(scalar));
        }
    }
    // Anything still open never met its closer in the output: restore it.
    for (sentinel, slots) in open {
        pieces[slots[0]] = literal(sentinel).into();
        for &slot in &slots[1..] {
            pieces[slot] = "~>".into();
        }
    }
    pieces.concat() + &current
}

/// The id of the `[^rv-…]` ref straight after a closer: rendered as a
/// footnote link when its thread exists, or left as literal text when not.
fn ref_id(rest: &str) -> Option<String> {
    let end = rest.char_indices().nth(80).map_or(rest.len(), |(i, _)| i);
    let text = &rest[..end];
    for prefix in ["<sup class=\"footnote-ref\"><a href=\"#fn-", "[^"] {
        if let Some(after) = text.strip_prefix(prefix) {
            let id: String = after
                .chars()
                .take_while(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '-')
                .collect();
            if id.starts_with("rv-") && id.len() > 3 {
                return Some(id);
            }
        }
    }
    None
}

/// Each thread entry on its own line: the soft breaks between entries become
/// hard breaks inside `rv-` footnotes only. Hand-rolled equivalent of the
/// Swift side's `(<li id="fn-rv-[a-z0-9]+">\n<p[^>]*>)(.*?)(</p>)` match and
/// its `\n(?=@\S+ \d{4}-\d{2}-\d{2}( suggestion)?:)` replacement.
fn break_thread_entries(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut copied = 0;
    let mut search = 0;
    while let Some(found) = html[search..].find("<li id=\"fn-rv-") {
        let start = search + found;
        let Some(body) = thread_paragraph_body(html, start) else {
            search = start + 1;
            continue;
        };
        out.push_str(&html[copied..body.start]);
        out.push_str(&break_entries(&html[body.clone()]));
        copied = body.end;
        search = body.end + "</p>".len();
    }
    out.push_str(&html[copied..]);
    out
}

/// The paragraph body of an `rv-` footnote item opening at `start`.
fn thread_paragraph_body(html: &str, start: usize) -> Option<Range<usize>> {
    let bytes = html.as_bytes();
    let mut p = start + "<li id=\"fn-rv-".len();
    let id_start = p;
    while p < bytes.len() && is_id_char(bytes[p]) {
        p += 1;
    }
    if p == id_start || !html[p..].starts_with("\">\n<p") {
        return None;
    }
    p += "\">\n<p".len();
    p += html[p..].find('>')? + 1;
    let end = p + html[p..].find("</p>")?;
    Some(p..end)
}

fn break_entries(body: &str) -> String {
    let mut out = String::with_capacity(body.len());
    for (index, c) in body.char_indices() {
        if c == '\n' && starts_entry(&body[index + 1..]) {
            out.push_str("<br />\n");
        } else {
            out.push(c);
        }
    }
    out
}

/// `@\S+ \d{4}-\d{2}-\d{2}( suggestion)?:` at the start of `text`.
fn starts_entry(text: &str) -> bool {
    let Some(rest) = text.strip_prefix('@') else { return false };
    let author_end = rest.find(char::is_whitespace).unwrap_or(rest.len());
    if author_end == 0 {
        return false;
    }
    let Some(rest) = rest[author_end..].strip_prefix(' ') else { return false };
    let date = rest.as_bytes();
    let shape = b"dddd-dd-dd";
    if date.len() < shape.len()
        || !shape.iter().zip(date).all(|(&s, &c)| if s == b'd' { c.is_ascii_digit() } else { c == s })
    {
        return false;
    }
    let rest = &rest[shape.len()..];
    rest.starts_with(':') || rest.starts_with(" suggestion:")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The spec's own example, verbatim.
    const SPEC_EXAMPLE: &str = "\
The {==cache is invalidated on every save==}[^rv-k3f9] and the index is
{~~rebuilt lazily~>rebuilt eagerly on open~~}[^rv-p2x7] from disk.
{++Autosave writes are exempt.++}[^rv-p2x7] A point comment.[^rv-z9y8]

[^rv-k3f9]: @ulf 2026-10-14: True for autosave too?
    @claude 2026-10-14: No, see the added sentence.
[^rv-p2x7]: @claude 2026-10-14 suggestion: Eager rebuild avoids the first-scroll stall.
[^rv-z9y8]: @ulf 2026-10-14: Needs a source.
";

    #[test]
    fn spec_example_parses_cleanly() {
        let text = SPEC_EXAMPLE;
        let review = parse(text);
        assert_eq!(review.problems, vec![]);
        let kinds: Vec<_> = review.anchors.iter().map(|a| a.kind).collect();
        use AnchorKind::*;
        assert_eq!(kinds, vec![Highlight, Substitution, Insertion, Point]);
        let ids: Vec<_> = review.anchors.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, vec!["rv-k3f9", "rv-p2x7", "rv-p2x7", "rv-z9y8"]);

        let highlight = &review.anchors[0];
        assert_eq!(&text[highlight.range.clone()], "{==cache is invalidated on every save==}[^rv-k3f9]");
        assert_eq!(&text[highlight.inner.clone()], "cache is invalidated on every save");
        assert_eq!(&text[highlight.reference.clone()], "[^rv-k3f9]");

        let substitution = &review.anchors[1];
        assert_eq!(&text[substitution.old.clone().unwrap()], "rebuilt lazily");
        assert_eq!(&text[substitution.new.clone().unwrap()], "rebuilt eagerly on open");

        let point = &review.anchors[3];
        assert_eq!(&text[point.range.clone()], "[^rv-z9y8]");
        assert!(point.inner.is_empty());

        assert_eq!(review.threads.len(), 3);
        let first = &review.threads[0];
        assert_eq!(first.entries.len(), 2);
        assert_eq!(first.entries[1].author, "claude");
        assert_eq!(first.entries[1].body, "No, see the added sentence.");
        assert_eq!(review.threads[1].entries[0].kind, EntryKind::Suggestion);
    }

    #[test]
    fn markup_without_ref_is_not_an_anchor() {
        let review = parse("Plain {==highlight==} and {++insert++} here.\n");
        assert_eq!(review.anchors, vec![]);
        assert_eq!(review.problems, vec![]);
    }

    #[test]
    fn non_review_footnotes_are_left_alone() {
        let review = parse("A {==note==}[^1] and[^note].\n\n[^1]: Ordinary footnote.\n[^note]: Another.\n");
        assert_eq!(review.anchors, vec![]);
        assert_eq!(review.threads, vec![]);
    }

    #[test]
    fn problems_are_reported() {
        let review = parse("{==a==}[^rv-aaaa] and {==b\n\n[^rv-bbbb]: @x 2026-10-14: y\n");
        assert!(review.problems.contains(&Problem::DanglingAnchor { id: "rv-aaaa".into(), range: 0..17 }));
        assert!(review.problems.iter().any(|p| matches!(p, Problem::OrphanThread { id, .. } if id == "rv-bbbb")));
        assert!(review.problems.iter().any(|p| matches!(p, Problem::Unbalanced { .. })));
    }

    #[test]
    fn markup_in_code_is_literal() {
        let review = parse("`{==y==}[^rv-aaaa]`\n\n```\n{++z++}[^rv-aaaa]\n```\n");
        assert_eq!(review.anchors, vec![]);
        assert_eq!(review.literal_spans.len(), 1);
        assert_eq!(review.literal_blocks.len(), 1);
    }

    #[test]
    fn multibyte_text_keeps_ranges_on_char_boundaries() {
        let text = "Æble {==ø 🍎==}[^rv-aaaa] så.\n\n[^rv-aaaa]: @x 2026-10-14: ✓\n";
        let review = parse(text);
        assert_eq!(&text[review.anchors[0].inner.clone()], "ø 🍎");
        assert_eq!(review.threads[0].entries[0].body, "✓");
    }

    #[test]
    fn encoding_keeps_one_line_byte_lengths() {
        let line = "A {==b==}[^rv-aaaa] {~~c~>d~~}[^rv-bbbb] {++e++}[^rv-aaaa] {--f--}[^rv-aaaa]";
        let encoded = sentinel_encoded(&format!("{line}\n")).unwrap();
        assert_eq!(encoded.len(), line.len() + 1);
    }

    #[test]
    fn unclosed_sentinels_fall_back_to_literals() {
        assert_eq!(tagged("a\u{E000}b"), "a{==b");
        assert_eq!(tagged("\u{E006}a\u{E007}b"), "{~~a~>b");
        assert_eq!(tagged("x\u{E001}"), "x==}");
    }

    #[test]
    fn entries_break_only_inside_review_threads() {
        let html = "<li id=\"fn-rv-ab12\">\n<p>@a 2026-01-01: x\n@b 2026-01-02 suggestion: y</p>\n\
                    <li id=\"fn-1\">\n<p>@a 2026-01-01: x\n@b 2026-01-02: y</p>\n";
        assert_eq!(
            break_thread_entries(html),
            "<li id=\"fn-rv-ab12\">\n<p>@a 2026-01-01: x<br />\n@b 2026-01-02 suggestion: y</p>\n\
             <li id=\"fn-1\">\n<p>@a 2026-01-01: x\n@b 2026-01-02: y</p>\n"
        );
    }
}
