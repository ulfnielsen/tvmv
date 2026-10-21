//! Review operations as plain text edits. A port of `ReviewOperations.swift`.
//!
//! Every operation returns edits against the parsed text: byte ranges,
//! ascending and non-overlapping, so the view applies them as one undoable
//! step through its single edit path. An operation that cannot be expressed
//! as well-formed markup (a range across blocks, inside code, or overlapping
//! another anchor) returns no edits rather than a broken file. Each one also
//! re-parses its own result and returns nothing if the outcome is not
//! exactly what it meant to write.

use std::collections::HashSet;
use std::ops::Range;

use crate::review::{self, Anchor, AnchorKind, Review, Thread};

/// A replacement of `range` with `insert`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Edit {
    pub range: Range<usize>,
    pub insert: String,
}

impl Edit {
    fn at(at: usize, insert: impl Into<String>) -> Edit {
        Edit { range: at..at, insert: insert.into() }
    }
}

/// Apply ascending, non-overlapping `edits` to `text`; `None` if they are not.
pub fn apply(edits: &[Edit], text: &str) -> Option<String> {
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    for e in edits {
        if e.range.start < at || e.range.end < e.range.start || e.range.end > text.len() {
            return None;
        }
        out.push_str(text.get(at..e.range.start)?);
        out.push_str(&e.insert);
        at = e.range.end;
    }
    out.push_str(text.get(at..)?);
    Some(out)
}

const ID_ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";

/// A fresh `rv-` id: four random characters, so two branches never mint the
/// same one. `next(n)` returns a random number below `n`.
pub fn new_id_with(existing: &HashSet<String>, mut next: impl FnMut(usize) -> usize) -> String {
    loop {
        let suffix: String = (0..4).map(|_| ID_ALPHABET[next(ID_ALPHABET.len())] as char).collect();
        let id = format!("rv-{suffix}");
        if !existing.contains(&id) {
            return id;
        }
    }
}

pub fn new_id(existing: &HashSet<String>) -> String {
    new_id_with(existing, |n| glib::random_int_range(0, n as i32) as usize)
}

/// Who and when, for a new entry. `date` is the local day, `YYYY-MM-DD`.
#[derive(Clone, Debug)]
pub struct Byline<'a> {
    pub author: &'a str,
    pub date: &'a str,
}

/// The parsed review of `text`, with the operations on it.
pub struct Ops<'a> {
    pub text: &'a str,
    pub review: Review,
}

impl<'a> Ops<'a> {
    pub fn new(text: &'a str) -> Ops<'a> {
        Ops { text, review: review::parse(text) }
    }

    pub fn ids(&self) -> HashSet<String> {
        self.review.anchors.iter().map(|a| a.id.clone()).chain(self.review.threads.iter().map(|t| t.id.clone())).collect()
    }

    pub fn thread(&self, id: &str) -> Option<&Thread> {
        self.review.threads.iter().find(|t| t.id == id)
    }

    pub fn anchors(&self, id: &str) -> impl Iterator<Item = &Anchor> {
        self.review.anchors.iter().filter(move |a| a.id == id)
    }

    fn bytes(&self) -> &[u8] {
        self.text.as_bytes()
    }

    // MARK: Create

    /// Comment on `range`: a highlight, or a point comment when the range is
    /// empty. A range inside a code fence or math block becomes a point
    /// comment on its own line directly after the block.
    pub fn add_comment(&self, range: Range<usize>, body: &str, by: &Byline, id: Option<&str>) -> Vec<Edit> {
        let id = id.map_or_else(|| new_id(&self.ids()), str::to_string);
        if !self.is_fresh(&id) || range.end > self.text.len() || !self.on_boundaries(&range) {
            return vec![];
        }
        let definition = self.definition_edit(&id, false, body, by);
        if let Some(block) = self.review.literal_blocks.iter().find(|b| b.start <= range.start && range.end <= b.end) {
            let end = block.end;
            let point = if end < self.text.len() {
                Edit::at(end + 1, format!("[^{id}]\n"))
            } else {
                Edit::at(end, format!("\n[^{id}]"))
            };
            return self.verified(vec![point, definition], &id, AnchorKind::Point, &[""]);
        }
        if !self.is_placeable(&range) {
            return vec![];
        }
        if range.is_empty() {
            let point = Edit::at(range.start, format!("[^{id}]"));
            return self.verified(vec![point, definition], &id, AnchorKind::Point, &[""]);
        }
        let inner = &self.text[range.clone()];
        self.verified(
            vec![Edit::at(range.start, "{=="), Edit::at(range.end, format!("==}}[^{id}]")), definition],
            &id,
            AnchorKind::Highlight,
            &[inner],
        )
    }

    /// Suggest replacing `range` with `replacement`: a substitution, an
    /// insertion when the range is empty, or a deletion when the replacement is.
    pub fn add_suggestion(&self, range: Range<usize>, replacement: &str, body: &str, by: &Byline, id: Option<&str>) -> Vec<Edit> {
        let id = id.map_or_else(|| new_id(&self.ids()), str::to_string);
        if !self.is_fresh(&id)
            || range.end > self.text.len()
            || !self.on_boundaries(&range)
            || (range.is_empty() && replacement.is_empty())
            || has_blank_line(replacement.as_bytes())
            || !self.is_placeable(&range)
            || self.review.literal_blocks.iter().any(|b| touches(&range, b))
        {
            return vec![];
        }
        let definition = self.definition_edit(&id, true, body, by);
        let reference = format!("[^{id}]");
        let (start, end) = (range.start, range.end);
        if range.is_empty() {
            return self.verified(
                vec![Edit::at(start, format!("{{++{replacement}++}}{reference}")), definition],
                &id,
                AnchorKind::Insertion,
                &[replacement],
            );
        }
        let old = &self.text[range.clone()];
        if replacement.is_empty() {
            return self.verified(
                vec![Edit::at(start, "{--"), Edit::at(end, format!("--}}{reference}")), definition],
                &id,
                AnchorKind::Deletion,
                &[old],
            );
        }
        self.verified(
            vec![Edit::at(start, "{~~"), Edit::at(end, format!("~>{replacement}~~}}{reference}")), definition],
            &id,
            AnchorKind::Substitution,
            &[old, replacement],
        )
    }

    /// Append an entry to the thread for `id`, after its last line.
    pub fn reply(&self, id: &str, body: &str, by: &Byline) -> Vec<Edit> {
        let Some(thread) = self.thread(id) else { return vec![] };
        let entry: Vec<String> = entry_lines(false, body, by).iter().map(|l| format!("    {l}")).collect();
        let entry = entry.join("\n");
        let end = thread.range.end;
        let edit = if end > 0 && self.bytes()[end - 1] == b'\n' {
            Edit::at(end, format!("{entry}\n"))
        } else {
            Edit::at(end, format!("\n{entry}"))
        };
        let Some(result) = apply(std::slice::from_ref(&edit), self.text) else { return vec![] };
        let after = review::parse(&result);
        let entries = after.threads.iter().find(|t| t.id == id).map(|t| t.entries.len());
        if after.problems.len() != self.review.problems.len() || entries != Some(thread.entries.len() + 1) {
            return vec![];
        }
        vec![edit]
    }

    // MARK: Settle

    /// Resolve a comment thread: highlights keep their text, point refs and
    /// the definition go. Suggestions are accepted or rejected instead, so an
    /// id with any suggestion anchor returns no edits.
    pub fn resolve(&self, id: &str) -> Vec<Edit> {
        if self.anchors(id).any(|a| a.kind.is_suggestion()) {
            return vec![];
        }
        self.settle(&HashSet::from([id.to_string()]), true)
    }

    /// Accept every anchor under `id` (a comment id is resolved).
    pub fn accept(&self, id: &str) -> Vec<Edit> {
        self.settle(&HashSet::from([id.to_string()]), true)
    }

    /// Reject every anchor under `id` (a comment id is resolved).
    pub fn reject(&self, id: &str) -> Vec<Edit> {
        self.settle(&HashSet::from([id.to_string()]), false)
    }

    /// Accept every suggestion thread. Comment threads stay open.
    pub fn accept_all(&self) -> Vec<Edit> {
        self.settle(&self.suggestion_ids(), true)
    }

    /// Reject every suggestion thread. Comment threads stay open.
    pub fn reject_all(&self) -> Vec<Edit> {
        self.settle(&self.suggestion_ids(), false)
    }

    fn suggestion_ids(&self) -> HashSet<String> {
        self.review.anchors.iter().filter(|a| a.kind.is_suggestion()).map(|a| a.id.clone()).collect()
    }

    fn settle(&self, ids: &HashSet<String>, accepting: bool) -> Vec<Edit> {
        let mut removals: Vec<Range<usize>> = Vec::new();
        for anchor in self.review.anchors.iter().filter(|a| ids.contains(&a.id)) {
            removals.extend(self.settle_removals(anchor, accepting));
        }
        let blocks: Vec<Range<usize>> =
            self.review.threads.iter().filter(|t| ids.contains(&t.id)).map(|t| t.range.clone()).collect();
        removals.extend(self.definition_removals(blocks));
        if removals.is_empty() {
            return vec![];
        }
        removals.sort_by_key(|r| r.start);
        let mut previous = 0;
        for r in &removals {
            if r.start < previous {
                return vec![]; // never overlap
            }
            previous = r.end;
        }
        let edits: Vec<Edit> =
            removals.into_iter().filter(|r| !r.is_empty()).map(|r| Edit { range: r, insert: String::new() }).collect();
        let Some(result) = apply(&edits, self.text) else { return vec![] };
        let after = review::parse(&result);
        let still: HashSet<&String> = after.anchors.iter().map(|a| &a.id).chain(after.threads.iter().map(|t| &t.id)).collect();
        if ids.iter().any(|id| still.contains(id)) {
            return vec![];
        }
        edits
    }

    /// The text to cut for one anchor, per the settle table in the spec.
    fn settle_removals(&self, anchor: &Anchor, accepting: bool) -> Vec<Range<usize>> {
        let keep = |inner: &Range<usize>| vec![anchor.range.start..inner.start, inner.end..anchor.range.end];
        match anchor.kind {
            AnchorKind::Highlight => keep(&anchor.inner),
            AnchorKind::Point => vec![self.point_removal(anchor.range.clone())],
            AnchorKind::Insertion => {
                if accepting {
                    keep(&anchor.inner)
                } else {
                    vec![anchor.range.clone()]
                }
            }
            AnchorKind::Deletion => {
                if accepting {
                    vec![anchor.range.clone()]
                } else {
                    keep(&anchor.inner)
                }
            }
            AnchorKind::Substitution => match (&anchor.old, &anchor.new) {
                (Some(old), Some(new)) => keep(if accepting { new } else { old }),
                _ => vec![],
            },
        }
    }

    /// A point ref alone on its line (a comment on a code block) takes its
    /// line with it; elsewhere only the ref goes.
    fn point_removal(&self, r: Range<usize>) -> Range<usize> {
        let b = self.bytes();
        let at_line_start = r.start == 0 || b[r.start - 1] == b'\n';
        let at_line_end = r.end == b.len() || b[r.end] == b'\n';
        if !(at_line_start && at_line_end) {
            return r;
        }
        if r.end < b.len() {
            return r.start..r.end + 1;
        }
        if r.start > 0 {
            return r.start - 1..r.end;
        }
        r
    }

    /// Definition blocks to cut. Adjacent blocks merge into one run, and a run
    /// with a blank line before it and nothing but a blank line or the end of
    /// the file after it takes that blank line too, undoing the separator
    /// `add_comment` put before the first definition.
    fn definition_removals(&self, mut blocks: Vec<Range<usize>>) -> Vec<Range<usize>> {
        blocks.sort_by_key(|r| r.start);
        let mut runs: Vec<Range<usize>> = Vec::new();
        for block in blocks {
            match runs.last_mut() {
                Some(last) if last.end == block.start => last.end = block.end,
                _ => runs.push(block),
            }
        }
        let b = self.bytes();
        runs.into_iter()
            .map(|run| {
                let start = run.start;
                let blank_before = start >= 1 && b[start - 1] == b'\n' && (start == 1 || b[start - 2] == b'\n');
                let blank_after = run.end == b.len() || b[run.end] == b'\n';
                if blank_before && blank_after { start - 1..run.end } else { run }
            })
            .collect()
    }

    // MARK: Helpers

    fn is_fresh(&self, id: &str) -> bool {
        id.strip_prefix("rv-").is_some_and(|s| !s.is_empty() && s.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()))
            && !self.ids().contains(id)
    }

    fn on_boundaries(&self, r: &Range<usize>) -> bool {
        r.start <= r.end && self.text.is_char_boundary(r.start) && self.text.is_char_boundary(r.end)
    }

    /// Whether the line holding offset `p` is blank. Markup written there
    /// would fill the blank line and merge the blocks around it.
    fn is_on_blank_line(&self, p: usize) -> bool {
        let b = self.bytes();
        let start = b[..p].iter().rposition(|&c| c == b'\n').map_or(0, |i| i + 1);
        let end = b[p..].iter().position(|&c| c == b'\n').map_or(b.len(), |i| p + i);
        b[start..end].iter().all(|&c| c == b' ' || c == b'\t' || c == b'\r')
    }

    /// Whether new delimiters can wrap `range`: one block, outside code spans,
    /// thread definitions and every existing anchor.
    fn is_placeable(&self, range: &Range<usize>) -> bool {
        if has_blank_line(&self.bytes()[range.clone()]) {
            return false;
        }
        if self.is_on_blank_line(range.start) || self.is_on_blank_line(range.end) {
            return false;
        }
        if self.review.anchors.iter().any(|a| touches(range, &a.range)) {
            return false;
        }
        if self.review.threads.iter().any(|t| touches(range, &t.range) || range.start == t.range.start) {
            return false;
        }
        let inside = |span: &Range<usize>, p: usize| span.start < p && p < span.end;
        !self.review.literal_spans.iter().any(|s| inside(s, range.start) || inside(s, range.end))
    }

    /// Apply `edits` and confirm the result holds exactly one new anchor of
    /// `kind` under `id`, with the intended text, a one-entry thread, and no
    /// new problems. Anything else returns no edits.
    fn verified(&self, edits: Vec<Edit>, id: &str, kind: AnchorKind, expected: &[&str]) -> Vec<Edit> {
        let Some(result) = apply(&edits, self.text) else { return vec![] };
        let after = review::parse(&result);
        let anchors: Vec<&Anchor> = after.anchors.iter().filter(|a| a.id == id).collect();
        let entries = after.threads.iter().find(|t| t.id == id).map(|t| t.entries.len());
        let [anchor] = anchors.as_slice() else { return vec![] };
        if anchor.kind != kind || entries != Some(1) || after.problems.len() != self.review.problems.len() {
            return vec![];
        }
        let excerpt = |r: &Option<Range<usize>>| r.as_ref().and_then(|r| result.get(r.clone()));
        let actual: Vec<Option<&str>> = if kind == AnchorKind::Substitution {
            vec![excerpt(&anchor.old), excerpt(&anchor.new)]
        } else {
            vec![excerpt(&Some(anchor.inner.clone()))]
        };
        if actual == expected.iter().map(|s| Some(*s)).collect::<Vec<_>>() { edits } else { vec![] }
    }

    fn definition_edit(&self, id: &str, suggestion: bool, body: &str, by: &Byline) -> Edit {
        let definition = format!("[^{id}]: {}\n", entry_lines(suggestion, body, by).join("\n    "));
        // Directly after an existing thread at the end of the file; otherwise
        // after a blank line, which keeps the definitions out of the last
        // paragraph.
        let b = self.bytes();
        let count = b.len();
        let mut content_end = count;
        while content_end > 0 && matches!(b[content_end - 1], b'\n' | b' ' | b'\t') {
            content_end -= 1;
        }
        let ends_with_newline = count > 0 && b[count - 1] == b'\n';
        let prefix = if content_end == 0 || self.review.threads.iter().any(|t| t.range.contains(&(content_end - 1))) {
            if count == 0 || ends_with_newline { "" } else { "\n" }
        } else if ends_with_newline {
            if count >= 2 && b[count - 2] == b'\n' { "" } else { "\n" }
        } else {
            "\n\n"
        };
        Edit::at(count, format!("{prefix}{definition}"))
    }
}

/// Whether `a` and `b` share any position, treating an empty range as a
/// caret that must not sit strictly inside `b`.
fn touches(a: &Range<usize>, b: &Range<usize>) -> bool {
    if a.is_empty() { b.start < a.start && a.start < b.end } else { a.start < b.end && a.end > b.start }
}

fn has_blank_line(bytes: &[u8]) -> bool {
    let mut saw_newline = false;
    for &c in bytes {
        if c == b'\n' {
            if saw_newline {
                return true;
            }
            saw_newline = true;
        } else if c != b' ' && c != b'\t' {
            saw_newline = false;
        }
    }
    false
}

/// `@author YYYY-MM-DD[ suggestion]: first line`, then any further body
/// lines. Blank lines would end the footnote, so they are dropped.
fn entry_lines(suggestion: bool, body: &str, by: &Byline) -> Vec<String> {
    // The entry form allows no space in the author.
    let name: String = by.author.trim_start_matches(|c: char| c == '@' || c.is_whitespace()).chars().take_while(|c| !c.is_whitespace()).collect();
    let name = if name.is_empty() { "anonymous".to_string() } else { name };
    let header = format!("@{name} {}{}", by.date, if suggestion { " suggestion:" } else { ":" });
    let lines: Vec<&str> = body.split('\n').map(str::trim).filter(|l| !l.is_empty()).collect();
    let Some(first) = lines.first() else { return vec![header] };
    std::iter::once(format!("{header} {first}")).chain(lines[1..].iter().map(|l| l.to_string())).collect()
}

// MARK: Cards

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CardKind {
    Comment,
    Suggestion,
    /// A thread whose anchor is gone.
    OrphanThread,
    /// An anchor whose thread is gone.
    DanglingAnchor,
}

/// What a margin card shows: one per thread, plus one per problem a hand
/// edit can leave. A port of `ReviewCards.Model`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CardModel {
    pub id: String,
    pub kind: CardKind,
    pub entries: Vec<review::Entry>,
    /// A suggestion's change in brief ("old → new", "+ added", "− removed").
    pub change: Option<String>,
    /// The source offset the card lines up with: its anchor's first visible
    /// character (an orphan thread's own start).
    pub anchor: usize,
}

impl CardModel {
    /// Same content, positions aside: the card can stay as it is.
    pub fn shows_same(&self, other: &CardModel) -> bool {
        let entries = |m: &CardModel| -> Vec<(String, String, review::EntryKind, String)> {
            m.entries.iter().map(|e| (e.author.clone(), e.date.clone(), e.kind, e.body.clone())).collect()
        };
        self.id == other.id && self.kind == other.kind && self.change == other.change && entries(self) == entries(other)
    }
}

/// The cards for `review` of `text`, in source order.
pub fn cards(review: &Review, text: &str) -> Vec<CardModel> {
    let slice = |r: &Option<Range<usize>>| r.as_ref().and_then(|r| text.get(r.clone())).unwrap_or("").to_string();
    let mut models = Vec::new();
    let mut seen = HashSet::new();
    for anchor in &review.anchors {
        if !seen.insert(anchor.id.clone()) {
            continue;
        }
        let start = if anchor.kind == AnchorKind::Point {
            anchor.reference.start
        } else {
            anchor.old.as_ref().unwrap_or(&anchor.inner).start
        };
        let Some(thread) = review.threads.iter().find(|t| t.id == anchor.id) else {
            models.push(CardModel { id: anchor.id.clone(), kind: CardKind::DanglingAnchor, entries: vec![], change: None, anchor: start });
            continue;
        };
        let suggestion = review.anchors.iter().any(|a| a.id == anchor.id && a.kind.is_suggestion());
        let change = match anchor.kind {
            AnchorKind::Substitution => Some(format!("{} → {}", slice(&anchor.old), slice(&anchor.new))),
            AnchorKind::Insertion => Some(format!("+ {}", slice(&Some(anchor.inner.clone())))),
            AnchorKind::Deletion => Some(format!("− {}", slice(&Some(anchor.inner.clone())))),
            AnchorKind::Highlight | AnchorKind::Point => None,
        };
        models.push(CardModel {
            id: anchor.id.clone(),
            kind: if suggestion { CardKind::Suggestion } else { CardKind::Comment },
            entries: thread.entries.clone(),
            change,
            anchor: start,
        });
    }
    for thread in &review.threads {
        if seen.insert(thread.id.clone()) {
            models.push(CardModel {
                id: thread.id.clone(),
                kind: CardKind::OrphanThread,
                entries: thread.entries.clone(),
                change: None,
                anchor: thread.range.start,
            });
        }
    }
    models.sort_by_key(|m| m.anchor);
    models
}

/// Tops for items wanting to sit at `wanted` (each with its height), without
/// overlapping: the pinned one (the focused card, the composer) exactly at
/// its line, those after it pushed down, those before it pushed up, and all
/// of them down again if that runs past `top`.
pub fn stack(items: &[(i32, i32)], pinned: Option<usize>, gap: i32, top: i32) -> Vec<i32> {
    if items.is_empty() {
        return vec![];
    }
    let mut tops: Vec<i32> = items.iter().map(|i| i.0).collect();
    let p = pinned.unwrap_or(0).min(items.len() - 1);
    for i in p + 1..items.len() {
        tops[i] = items[i].0.max(tops[i - 1] + items[i - 1].1 + gap);
    }
    for i in (0..p).rev() {
        tops[i] = items[i].0.min(tops[i + 1] - gap - items[i].1);
    }
    if tops[0] < top {
        // Out of room above: push the whole stack down.
        tops[0] = top;
        for i in 1..tops.len() {
            tops[i] = tops[i].max(tops[i - 1] + items[i - 1].1 + gap);
        }
    }
    tops
}

/// Where a caret at `at` belongs after `edits`: shifted past the ones before
/// it, and at the end of one it was inside. A new thread definition never
/// carries it along: at the end of the text that would leave the caret
/// behind the hidden thread.
pub fn caret_through(at: usize, edits: &[Edit]) -> usize {
    let mut shift: isize = 0;
    for e in edits {
        let len = e.insert.len() as isize;
        if e.range.end <= at {
            if e.range.start == at && e.insert.contains("]: @") {
                continue;
            }
            shift += len - e.range.len() as isize;
        } else if e.range.start < at {
            return (e.range.start as isize + shift + len) as usize;
        }
    }
    (at as isize + shift).max(0) as usize
}

// MARK: Author

/// Who a review entry is by: the first word of git's user.name, lowercased;
/// without git, the account's name.
pub fn author_handle(git_name: Option<&str>, account: &str) -> String {
    git_name.and_then(|n| n.split_whitespace().next()).unwrap_or(account).to_lowercase()
}

/// git's user.name for documents in `folder`: its repository's config, then
/// the global ones. Read from the files, not by running git.
pub fn git_user_name(folder: Option<&std::path::Path>, home: &std::path::Path) -> Option<String> {
    let mut configs = Vec::new();
    let mut dir = folder.map(std::path::Path::to_path_buf);
    while let Some(current) = dir {
        let dot_git = current.join(".git");
        if dot_git.exists() {
            if dot_git.is_dir() {
                configs.push(dot_git.join("config"));
            }
            break;
        }
        dir = current.parent().map(std::path::Path::to_path_buf);
    }
    configs.push(home.join(".gitconfig"));
    configs.push(home.join(".config/git/config"));
    configs.iter().filter_map(|c| std::fs::read_to_string(c).ok()).find_map(|t| user_name_in_config(&t))
}

/// `name` in the `[user]` section of a git config file.
pub fn user_name_in_config(text: &str) -> Option<String> {
    let mut in_user = false;
    for raw in text.lines() {
        let line = raw.trim();
        if line.starts_with('[') {
            in_user = line.to_lowercase().starts_with("[user]");
            continue;
        }
        let Some((key, value)) = line.split_once('=') else { continue };
        if !in_user || key.trim().to_lowercase() != "name" {
            continue;
        }
        let value = value.trim();
        let value = if let Some(rest) = value.strip_prefix('"') {
            rest.split('"').next().unwrap_or("").to_string()
        } else {
            value.split([';', '#']).next().unwrap_or("").trim().to_string()
        };
        return (!value.is_empty()).then_some(value);
    }
    None
}

/// The handle for documents in `folder`.
pub fn current_author(folder: Option<&std::path::Path>) -> String {
    let home = glib::home_dir();
    let account = glib::user_name().to_string_lossy().into_owned();
    author_handle(git_user_name(folder, &home).as_deref(), &account)
}
