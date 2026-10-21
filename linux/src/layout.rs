//! Everything the native view needs to draw a Markdown text in place: which
//! ranges get which style, which markup characters hide, and which spans
//! reveal together.
//!
//! A port of `MarkdownLayout.swift`, `MarkdownLayoutParser.swift`,
//! `MarkdownLayoutDiff.swift`, `ReviewLayout.swift` and `SourceMap.swift`;
//! any change here needs the matching change there. All ranges are UTF-8
//! byte ranges in the source text (the Swift side counts UTF-16).

use std::ops::Range;
use std::rc::Rc;

use crate::cmark::{Document, Node};
use crate::review::{self, Review};
use crate::review_spans::{self, SpanRole};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Style {
    Emphasis,
    Strong,
    Strikethrough,
    Code,
    Link { url: String },
    Autolink { url: String },
    Heading { level: usize },
    CodeBlock { language: Option<String> },
    Html,
    Image,
    /// Review markup: a commented range, one side of a suggestion, or the
    /// character that carries a point comment's marker.
    Review { role: SpanRole, id: String },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StyleRun {
    pub range: Range<usize>,
    pub style: Style,
}

/// Markup that is hidden unless the span it belongs to is revealed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Marker {
    pub range: Range<usize>,
    /// The construct this marker belongs to: the span a double-click or
    /// Ctrl+' reveals. Revealing a unit shows all of its markers.
    pub unit: Range<usize>,
    /// The marker is a whole line (a code fence, a setext underline),
    /// including its newline, and collapses to zero height when hidden.
    pub collapses_line: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodeBlock {
    /// The whole block, fences included.
    pub range: Range<usize>,
    /// The code lines only (what gets the block background).
    pub body: Range<usize>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Heading {
    pub level: usize,
    /// Rendered text: markup removed, soft breaks as spaces, trimmed.
    pub title: String,
    pub range: Range<usize>,
}

/// A top-level block.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Block {
    pub range: Range<usize>,
    pub kind: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ListItem {
    /// Indentation, bullet, space and any "[ ] ": everything before the
    /// item's text on its first line (after a quote prefix). Also its reveal unit.
    pub marker: Range<usize>,
    /// "-", "*", "+", "3." or "3)".
    pub bullet: Range<usize>,
    /// Nesting depth, 0 for a top-level list.
    pub level: usize,
    pub ordered: bool,
    /// None for a plain item; checked state for a task item.
    pub task: Option<bool>,
    /// The "[ ]" / "[x]" of a task item.
    pub checkbox: Option<Range<usize>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QuoteLine {
    /// Leading spaces and every ">" (with its following space). Also its reveal unit.
    pub prefix: Range<usize>,
    /// How many ">": the nesting depth.
    pub level: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Alignment {
    None,
    Left,
    Right,
    Center,
}

/// A top-level GFM table: shown as an editable grid over its hidden source.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Table {
    /// The whole table source, header line through the last row (no final newline).
    pub range: Range<usize>,
    /// Header row first, then body rows (the delimiter row is not a row).
    /// Each cell is its content only: no pipes, no padding; an empty cell is
    /// a zero-length range inside its pipes.
    pub rows: Vec<Vec<Range<usize>>>,
    pub alignments: Vec<Alignment>,
}

/// An image that is the whole content of a top-level paragraph: shown as the
/// picture itself, with the `![alt](url)` source hidden until revealed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlockImage {
    /// The `![alt](url "title")` source; also its reveal unit.
    pub range: Range<usize>,
    pub url: String,
    pub alt: String,
}

/// A link reference definition line (`[label]: url`) outside code.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Definition {
    pub range: Range<usize>,
    pub text: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Layout {
    pub length: usize,
    pub styles: Vec<StyleRun>,
    pub markers: Vec<Marker>,
    pub spell_exempt: Vec<Range<usize>>,
    pub code_blocks: Vec<CodeBlock>,
    pub headings: Vec<Heading>,
    pub blocks: Vec<Block>,
    /// Newlines inside top-level paragraphs that are soft line breaks: the
    /// paragraph reflows across them, so they lay out as spaces.
    pub soft_breaks: Vec<usize>,
    /// List items: the marker hides and a bullet, number or checkbox is drawn.
    pub list_items: Vec<ListItem>,
    /// Quoted lines: the "> " prefix hides and a rule is drawn.
    pub quote_lines: Vec<QuoteLine>,
    pub tables: Vec<Table>,
    pub block_images: Vec<BlockImage>,
    pub definitions: Vec<Definition>,
    /// The document's review markup, when it has any: anchors, threads and
    /// problems for the margin cards. Its spans are folded into the vectors above.
    pub review: Option<Review>,
}

/// True when `inner` lies entirely within `outer` (an empty `inner` may sit at either end).
pub fn encloses(outer: &Range<usize>, inner: &Range<usize>) -> bool {
    inner.start >= outer.start && inner.end <= outer.end
}

fn meets(a: &Range<usize>, b: &Range<usize>) -> bool {
    a.start.max(b.start) < a.end.min(b.end)
}

fn union(a: &Range<usize>, b: &Range<usize>) -> Range<usize> {
    a.start.min(b.start)..a.end.max(b.end)
}

fn shifted(r: &Range<usize>, delta: isize) -> Range<usize> {
    r.start.wrapping_add_signed(delta)..r.end.wrapping_add_signed(delta)
}

impl Layout {
    /// Every reveal unit, in source order without duplicates.
    pub fn reveal_units(&self) -> Vec<Range<usize>> {
        let mut seen = std::collections::HashSet::new();
        self.markers
            .iter()
            .map(|m| m.unit.clone())
            .chain(self.block_images.iter().map(|i| i.range.clone()))
            .chain(self.tables.iter().map(|t| t.range.clone()))
            .chain(self.list_items.iter().map(|l| l.marker.clone()))
            .chain(self.quote_lines.iter().map(|q| q.prefix.clone()))
            .filter(|r| seen.insert(r.clone()))
            .collect()
    }
}

// MARK: Parsing

/// Full parse of `text`.
pub fn parse(text: &str) -> Layout {
    let all = definitions(text);
    let mut builder = Builder::new(text, 0, "", &[], &all, true);
    builder.parse();
    let mut layout = builder.layout;
    layout.length = text.len();
    let code: Vec<Range<usize>> = layout.code_blocks.iter().map(|c| c.range.clone()).collect();
    layout.definitions = all.into_iter().filter(|d| !code.iter().any(|c| meets(c, &d.range))).collect();
    if may_have_review_markup(text) {
        layout.fold(review::parse(text));
    }
    layout
}

/// Link reference definition lines: `[label]: destination ...`, up to three
/// spaces of indent. Footnote-style labels (`[^x]:`) are included: with
/// footnotes off, cmark treats them as reference definitions too.
fn definitions(text: &str) -> Vec<Definition> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let mut start = 0;
    while start <= text.len() {
        let end = text[start..].find('\n').map_or(text.len(), |i| start + i);
        let mut i = start;
        while i < end && i - start < 3 && bytes[i] == b' ' {
            i += 1;
        }
        if i < end && bytes[i] == b'[' {
            let label = i + 1;
            let mut close = label;
            while close < end && bytes[close] != b']' {
                close += 1;
            }
            if close > label && close + 1 < end && bytes[close + 1] == b':' {
                out.push(Definition { range: start..end, text: text[start..end].to_string() });
            }
        }
        if end == text.len() {
            break;
        }
        start = end + 1;
    }
    out
}

/// Converts cmark's 1-based (line, byte column) source positions into byte
/// offsets that fall on character boundaries.
///
/// A position can name any byte of a multi-byte character, so offsets snap
/// back to the character containing it, and exclusive ends snap forward to
/// the next character boundary.
pub struct SourceMap {
    bytes: Rc<str>,
    /// Byte offset where each line starts (index 0 is line 1).
    line_starts: Vec<usize>,
}

impl SourceMap {
    pub fn new(text: &str) -> SourceMap {
        Self::from_rc(Rc::from(text))
    }

    fn from_rc(bytes: Rc<str>) -> SourceMap {
        let mut line_starts = vec![0];
        line_starts.extend(bytes.bytes().enumerate().filter(|&(_, b)| b == b'\n').map(|(i, _)| i + 1));
        SourceMap { bytes, line_starts }
    }

    fn is_continuation(&self, byte: usize) -> bool {
        self.bytes.as_bytes().get(byte).is_some_and(|b| b & 0xC0 == 0x80)
    }

    /// Offset of the character at (line, column); None when cmark reported no
    /// position (line 0) or the position is out of range.
    pub fn offset(&self, line: i64, column: i64) -> Option<usize> {
        if line < 1 || line as usize > self.line_starts.len() || column < 1 {
            return None;
        }
        let mut byte = self.line_starts[line as usize - 1] + column as usize - 1;
        if byte > self.bytes.len() {
            return None;
        }
        while byte > 0 && self.is_continuation(byte) {
            byte -= 1;
        }
        Some(byte)
    }

    /// Offset just past the character at (line, column). Column 0 means "the
    /// end of the previous line", which cmark uses for container blocks that
    /// end at a blank line.
    pub fn end_offset(&self, line: i64, column: i64) -> Option<usize> {
        if line < 1 || line as usize > self.line_starts.len() || column < 0 {
            return None;
        }
        let mut byte = self.line_starts[line as usize - 1] + column as usize;
        if byte > self.bytes.len() {
            return None;
        }
        while byte < self.bytes.len() && self.is_continuation(byte) {
            byte += 1;
        }
        Some(byte)
    }

    /// The range for cmark's inclusive start/end positions.
    pub fn range(&self, start_line: i64, start_column: i64, end_line: i64, end_column: i64) -> Option<Range<usize>> {
        let start = self.offset(start_line, start_column)?;
        let end = self.end_offset(end_line, end_column)?;
        (end >= start).then_some(start..end)
    }
}

/// `.whitespaces` in Foundation: tab and the space separators (Zs).
fn is_hspace(c: char) -> bool {
    matches!(c, '\t' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}')
}

fn trim_hspace(s: &str) -> &str {
    s.trim_matches(is_hspace)
}

/// Walks one cmark document and accumulates a `Layout`.
///
/// The parsed source is the text of interest, optionally wrapped: definition
/// lines from elsewhere in the document before and after it (they produce no
/// blocks, so they only make reference links resolve), and a sentinel just
/// before it. Offsets convert back to document offsets via `adjust`.
struct Builder<'d> {
    src: Rc<str>,
    map: SourceMap,
    /// Document offset = source offset + adjust.
    adjust: isize,
    /// Where the text of interest (including any sentinel) starts and ends in the source.
    content_start: usize,
    content_end: usize,
    record_blocks: bool,
    /// Every definition in the document, for segment re-parses.
    definitions: &'d [Definition],
    layout: Layout,
    /// Source offsets already hidden by some marker: a character belongs to
    /// at most one marker, whatever cmark's positions claim.
    claimed: Vec<bool>,
}

/// Deeper nesting than this is left unstyled (shown as typed): the walks
/// below recurse, and a document can nest thousands deep (">>>>…").
const MAX_DEPTH: usize = 64;

impl<'d> Builder<'d> {
    fn new(
        text: &str,
        doc_location: usize,
        sentinel: &str,
        wrap: &[Definition],
        definitions: &'d [Definition],
        record_blocks: bool,
    ) -> Builder<'d> {
        let before: Vec<&str> = wrap.iter().filter(|d| d.range.start < doc_location).map(|d| d.text.as_str()).collect();
        let after: Vec<&str> = wrap.iter().filter(|d| d.range.start >= doc_location).map(|d| d.text.as_str()).collect();
        let prefix = if before.is_empty() { String::new() } else { before.join("\n") + "\n\n" };
        let suffix = if after.is_empty() { String::new() } else { "\n\n".to_string() + &after.join("\n") };
        let src: Rc<str> = Rc::from(format!("{prefix}{sentinel}{text}{suffix}"));
        let content_start = prefix.len();
        Builder {
            map: SourceMap::from_rc(Rc::clone(&src)),
            claimed: vec![false; src.len()],
            src,
            adjust: doc_location as isize - content_start as isize - sentinel.len() as isize,
            content_start,
            content_end: content_start + sentinel.len() + text.len(),
            record_blocks,
            definitions,
            layout: Layout::default(),
        }
    }

    fn byte(&self, i: usize) -> u8 {
        self.src.as_bytes()[i]
    }

    fn len(&self) -> usize {
        self.src.len()
    }

    fn parse(&mut self) {
        let src = Rc::clone(&self.src);
        if let Some(doc) = Document::parse(&src) {
            let blocks = doc.root().children();
            for (i, &block) in blocks.iter().enumerate() {
                let Some(mut r) = self.local_range(block) else { continue };
                if r.start < self.content_start || r.start >= self.content_end {
                    continue;
                }
                let limit = match blocks.get(i + 1) {
                    Some(&next) => self.local_range(next).map_or(self.len(), |n| n.start),
                    None => self.len(),
                };
                r.end = r.start + r.len().min(limit.saturating_sub(r.start));
                if self.record_blocks {
                    self.record_containers(block, 0, 0, false);
                    self.layout.blocks.push(Block { range: self.doc_range(&r), kind: block.kind().to_string() });
                    if block.kind() == "table" {
                        self.record_table(&r);
                    }
                    if block.kind() == "paragraph" {
                        self.record_soft_breaks(&r);
                        self.record_block_image(block);
                    }
                }
                self.visit_block(block, limit, 0);
            }
        }
        self.layout.styles.retain(|s| !s.range.is_empty());
        self.layout.spell_exempt.retain(|r| !r.is_empty());
    }

    /// Every newline inside a top-level paragraph except one that ends a hard
    /// break ("\\" or two trailing spaces). Paragraphs inside lists and quotes
    /// keep their source layout: their next line carries a prefix.
    fn record_soft_breaks(&mut self, r: &Range<usize>) {
        for i in r.clone() {
            if self.byte(i) == b'\n' {
                let line = self.line_range(i);
                let content = &self.src[line.start..i];
                if !content.ends_with('\\') && !content.ends_with("  ") {
                    self.layout.soft_breaks.push(self.doc(i));
                }
            }
        }
    }

    /// The quote prefix at the start of the line containing `location` (empty
    /// if none): `^[ \t]{0,3}(?:>[ \t]?)+`.
    fn quote_prefix(&self, location: usize) -> Range<usize> {
        let line = self.line_range(location);
        let end = line.end;
        let mut i = line.start;
        while i < end && i - line.start < 3 && matches!(self.byte(i), b' ' | b'\t') {
            i += 1;
        }
        if i >= end || self.byte(i) != b'>' {
            return line.start..line.start;
        }
        while i < end && self.byte(i) == b'>' {
            i += 1;
            if i < end && matches!(self.byte(i), b' ' | b'\t') {
                i += 1;
            }
        }
        line.start..i
    }

    /// Lists (with their nesting level) and quotes, anywhere in the block tree.
    fn record_containers(&mut self, node: Node, level: usize, depth: usize, in_quote: bool) {
        if depth >= MAX_DEPTH {
            return;
        }
        match node.kind() {
            "list" => {
                let ordered = node.is_ordered_list();
                for item in node.children() {
                    self.record_list_item(item, level, ordered);
                    for child in item.children() {
                        self.record_containers(child, level + 1, depth + 2, in_quote);
                    }
                }
            }
            "block_quote" => {
                // The outermost quote records every line.
                if let Some(r) = self.local_range(node).filter(|_| !in_quote) {
                    let mut start = r.start;
                    while start < r.end {
                        let line = self.line_range(start);
                        let prefix = self.quote_prefix(start);
                        let level = self.src[prefix.clone()].bytes().filter(|&b| b == b'>').count();
                        if level > 0 {
                            self.layout.quote_lines.push(QuoteLine { prefix: self.doc_range(&prefix), level });
                        }
                        if line.end <= start {
                            break;
                        }
                        start = line.end;
                    }
                }
                for child in node.children() {
                    self.record_containers(child, level, depth + 1, true);
                }
            }
            _ => {
                for child in node.children() {
                    self.record_containers(child, level, depth + 1, in_quote);
                }
            }
        }
    }

    fn record_list_item(&mut self, item: Node, level: usize, ordered: bool) {
        let Some(r) = self.local_range(item) else { return };
        let line = self.line_range(r.start);
        let mut line_end = line.end;
        if line_end > line.start && self.byte(line_end - 1) == b'\n' {
            line_end -= 1;
        }
        let start = self.quote_prefix(r.start).end;
        // The text starts where the first child does, if that is on this line.
        let mut content_start = line_end;
        if let Some(first) = item.first_child().and_then(|f| self.local_range(f)) {
            if first.start < line_end {
                content_start = first.start;
            }
        }
        if content_start <= start || r.start < start {
            return;
        }
        let mut bullet_end = r.start;
        while bullet_end < content_start && !matches!(self.byte(bullet_end), b' ' | b'\t') {
            bullet_end += 1;
        }
        let is_task = item.kind() == "tasklist";
        let checkbox = if is_task {
            self.src[start..content_start].find('[').map(|open| start + open..start + open + 3)
        } else {
            None
        };
        self.layout.list_items.push(ListItem {
            marker: self.doc_range(&(start..content_start)),
            bullet: self.doc_range(&(r.start..bullet_end)),
            level,
            ordered,
            task: is_task.then(|| item.task_checked()),
            checkbox: checkbox.map(|c| self.doc_range(&c)),
        });
    }

    /// A table's rows and cells, split on unescaped pipes in each source line
    /// (cmark's cell positions include padding and can be missing for empty
    /// cells); cmark still decides that this is a table.
    fn record_table(&mut self, r: &Range<usize>) {
        let mut lines = Vec::new();
        let mut start = r.start;
        while start < r.end {
            let mut line = self.line_range(start);
            let next = line.end;
            if !line.is_empty() && self.byte(line.end - 1) == b'\n' {
                line.end -= 1;
            }
            line.end = line.end.min(r.end);
            lines.push(line);
            start = next;
        }
        if lines.len() < 2 {
            return;
        }
        let alignments = self
            .cells(&lines[1])
            .iter()
            .map(|(raw, _)| {
                let spec = trim_hspace(&self.src[raw.clone()]);
                match (spec.starts_with(':'), spec.ends_with(':')) {
                    (true, true) => Alignment::Center,
                    (true, false) => Alignment::Left,
                    (false, true) => Alignment::Right,
                    _ => Alignment::None,
                }
            })
            .collect();
        let rows: Vec<Vec<Range<usize>>> = std::iter::once(&lines[0])
            .chain(lines.iter().skip(2))
            .map(|line| self.cells(line).into_iter().map(|(_, content)| self.doc_range(&content)).collect())
            .collect();
        let range = r.start..lines[lines.len() - 1].end;
        self.layout.tables.push(Table { range: self.doc_range(&range), rows, alignments });
    }

    /// The cells of one table line: `raw` between the pipes, `content` trimmed.
    fn cells(&self, line: &Range<usize>) -> Vec<(Range<usize>, Range<usize>)> {
        let end = line.end;
        let mut i = line.start;
        while i < end && matches!(self.byte(i), b' ' | b'\t') {
            i += 1;
        }
        if i < end && self.byte(i) == b'|' {
            i += 1;
        }
        let mut out: Vec<(Range<usize>, Range<usize>)> = Vec::new();
        let mut cell_start = i;
        while i <= end {
            let at_end = i == end;
            if !at_end && self.byte(i) == b'\\' {
                i += 2;
                continue;
            }
            if at_end || self.byte(i) == b'|' {
                let raw = cell_start..i.min(end);
                let text = &self.src[raw.clone()];
                let trimmed = trim_hspace(text);
                let trailing_pipe_only = at_end && trimmed.is_empty() && !out.is_empty();
                if !trailing_pipe_only {
                    let leading = text.bytes().take_while(|&b| b == b' ' || b == b'\t').count();
                    let content = if trimmed.is_empty() {
                        let at = raw.start + raw.len().min(1);
                        at..at
                    } else {
                        raw.start + leading..raw.start + leading + trimmed.len()
                    };
                    out.push((raw, content));
                }
                cell_start = i + 1;
            }
            i += 1;
        }
        out
    }

    /// A paragraph whose only content is one image (whitespace aside).
    fn record_block_image(&mut self, paragraph: Node) {
        let content: Vec<Node> = paragraph
            .children()
            .into_iter()
            .filter(|c| {
                !(matches!(c.kind(), "softbreak" | "linebreak")
                    || (c.kind() == "text" && c.literal().chars().all(char::is_whitespace)))
            })
            .collect();
        if content.len() != 1 || content[0].kind() != "image" {
            return;
        }
        let Some(r) = self.local_range(content[0]) else { return };
        if r.end > self.len() || self.byte(r.start) != b'!' {
            return;
        }
        let image = BlockImage { range: self.doc_range(&r), url: content[0].url(), alt: plain_text(content[0], 0) };
        self.layout.block_images.push(image);
    }

    // MARK: Ranges

    /// Range of `node` in the parsed text (no adjustment); None without a position.
    fn local_range(&self, node: Node) -> Option<Range<usize>> {
        let (sl, sc, el, ec) = node.position();
        self.map.range(sl, sc, el, ec)
    }

    fn doc(&self, local: usize) -> usize {
        local.wrapping_add_signed(self.adjust)
    }

    fn doc_range(&self, local: &Range<usize>) -> Range<usize> {
        shifted(local, self.adjust)
    }

    /// The line containing `location`, with its newline.
    fn line_range(&self, location: usize) -> Range<usize> {
        let location = location.min(self.len());
        let bytes = self.src.as_bytes();
        let start = bytes[..location].iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
        let end = bytes[location..].iter().position(|&b| b == b'\n').map_or(self.len(), |i| location + i + 1);
        start..end
    }

    fn is_claimed(&self, r: &Range<usize>) -> bool {
        self.claimed[r.clone()].iter().any(|&c| c)
    }

    /// Record a marker unless it overlaps one already recorded. Every hide
    /// goes through here: hiding real text is the worst failure this layer
    /// can have, so anything doubtful stays visible instead.
    fn add_marker(&mut self, local: Range<usize>, unit: Range<usize>, collapses_line: bool) {
        if local.is_empty() || local.end > self.len() || self.is_claimed(&local) {
            return;
        }
        self.claimed[local.clone()].iter_mut().for_each(|c| *c = true);
        self.layout.markers.push(Marker { range: self.doc_range(&local), unit, collapses_line });
    }

    fn is_run(&self, r: &Range<usize>, of: &[u8]) -> bool {
        !r.is_empty() && r.end <= self.len() && self.src.as_bytes()[r.clone()].iter().all(|b| of.contains(b))
    }

    // MARK: Blocks

    /// `limit` is where the next sibling block starts. cmark's end position
    /// is wrong for blocks containing a hard line break, so every block range
    /// is clamped to it.
    fn visit_block(&mut self, node: Node, limit: usize, depth: usize) {
        if depth >= MAX_DEPTH {
            return;
        }
        let Some(mut r) = self.local_range(node) else { return };
        r.end = r.start + r.len().min(limit.saturating_sub(r.start));
        match node.kind() {
            "heading" => self.visit_heading(node, &r),
            "paragraph" | "table_cell" => self.visit_inline_container(node, &r),
            "code_block" => self.visit_code_block(node, &r),
            "html_block" => {
                let doc = self.doc_range(&r);
                self.layout.styles.push(StyleRun { range: doc.clone(), style: Style::Html });
                self.layout.spell_exempt.push(doc);
            }
            _ => {
                let children = node.children();
                for (i, &child) in children.iter().enumerate() {
                    let next = match children.get(i + 1) {
                        Some(&n) => self.local_range(n).map_or(limit, |n| n.start),
                        None => limit,
                    };
                    self.visit_block(child, next.min(limit), depth + 1);
                }
            }
        }
    }

    fn visit_heading(&mut self, node: Node, r: &Range<usize>) {
        let level = node.heading_level();
        let first_line = self.line_range(r.start);
        let mut line_end = first_line.end;
        if line_end > first_line.start && self.byte(line_end - 1) == b'\n' {
            line_end -= 1;
        }
        // The unit spans the whole heading: cmark's ATX range stops before a closing " ##".
        let last = self.line_range(r.start.max(r.end.saturating_sub(1)));
        let unit = self.doc_range(&union(&union(r, &(r.start..line_end)), &last));
        self.layout.styles.push(StyleRun { range: unit.clone(), style: Style::Heading { level } });
        if first_line.end < r.end {
            // Setext: the underline is the last line; it collapses away.
            let underline = self.line_range(r.end - 1);
            let text = self.src[underline.clone()].trim();
            if !text.is_empty() && (text.bytes().all(|b| b == b'=') || text.bytes().all(|b| b == b'-')) {
                self.add_marker(underline, unit.clone(), true);
            }
        } else {
            // ATX: hide "# " up to the content, and an optional closing " ##".
            let content_start = node.first_child().and_then(|c| self.local_range(c)).map_or(r.end, |c| c.start);
            if content_start > r.start {
                let prefix = r.start..content_start;
                if self.is_run(&prefix, b"# \t") {
                    self.add_marker(prefix, unit.clone(), false);
                }
            }
            // cmark's heading range stops before a closing " ##"; look on the whole line.
            if let Some(closing) = self.closing_hashes(first_line.start..line_end) {
                if closing.start >= content_start {
                    self.add_marker(closing, unit.clone(), false);
                }
            }
        }
        let title = trim_hspace(&plain_text(node, 0)).to_string();
        self.layout.headings.push(Heading { level, title, range: unit });
        self.visit_inline_container(node, r);
    }

    /// `[ \t]+#+[ \t]*$` within `line`: trailing blanks, hashes, and the blank
    /// run before them.
    fn closing_hashes(&self, line: Range<usize>) -> Option<Range<usize>> {
        let mut i = line.end;
        while i > line.start && matches!(self.byte(i - 1), b' ' | b'\t') {
            i -= 1;
        }
        let hashes_end = i;
        while i > line.start && self.byte(i - 1) == b'#' {
            i -= 1;
        }
        if i == hashes_end {
            return None;
        }
        let blanks_end = i;
        while i > line.start && matches!(self.byte(i - 1), b' ' | b'\t') {
            i -= 1;
        }
        (i < blanks_end).then_some(i..line.end)
    }

    fn visit_code_block(&mut self, node: Node, r: &Range<usize>) {
        // The unit spans the fence lines whole (container prefixes and newline included).
        let open = self.line_range(r.start);
        let last = self.line_range(r.start.max(r.end.saturating_sub(1)));
        let unit = self.doc_range(&union(&union(r, &open), &last));
        let mut body = r.clone();
        if let Some((length, character)) = node.fence() {
            let fence = (character as char).to_string().repeat(length);
            if length > 0 && self.src[open.clone()].contains(&fence) {
                self.add_marker(open.clone(), unit.clone(), true);
                body = open.end..open.end.max(r.end);
                let close = self.line_range(r.end.saturating_sub(1));
                // A closing fence is only fence characters (at least as many as
                // opened it); "```python" on the last line is still code.
                let close_text = self.src[close.clone()].trim();
                if close.start > open.start
                    && close_text.chars().count() >= length
                    && close_text.chars().all(|c| c == character as char)
                {
                    let close_start = close.start;
                    self.add_marker(close, unit.clone(), true);
                    body.end = body.start.max(close_start);
                }
                // The body's final newline belongs to the closing fence's line break.
                if !body.is_empty() && self.byte(body.end - 1) == b'\n' {
                    body.end -= 1;
                }
            }
        }
        let info = node.fence_info();
        let language = info.split(' ').find(|s| !s.is_empty()).map(str::to_string);
        self.layout.styles.push(StyleRun { range: unit.clone(), style: Style::CodeBlock { language } });
        self.layout.spell_exempt.push(unit.clone());
        let body = self.doc_range(&body);
        self.layout.code_blocks.push(CodeBlock { range: unit, body });
    }

    // MARK: Inlines

    /// Inline content of a paragraph, heading, or table cell. cmark's inline
    /// positions are wrong after a hard line break (the line number sticks
    /// and columns run on), so such containers are re-parsed segment by
    /// segment, each segment on its own.
    fn visit_inline_container(&mut self, node: Node, r: &Range<usize>) {
        if !contains_hard_break(node, 0) {
            for child in node.children() {
                self.visit_inline(child, 0);
            }
            return;
        }
        let mut segment_start = r.start;
        let mut line_start = r.start;
        while line_start < r.end {
            let line = self.line_range(line_start);
            let line_end = line.end.min(r.end);
            let text = &self.src[line_start..line_end];
            let content = text.strip_suffix('\n').unwrap_or(text);
            if content.ends_with('\\') || content.ends_with("  ") || line_end == r.end {
                self.visit_segment(segment_start..line_end);
                segment_start = line_end;
            }
            line_start = line_end;
        }
    }

    /// Parse one hard-break segment as its own document. The "." sentinel
    /// keeps its first line from parsing as a block start ("# ", "- ", ">").
    /// An emphasis that spans a hard break degrades to literal text here.
    fn visit_segment(&mut self, segment: Range<usize>) {
        let doc_location = self.doc(segment.start);
        let text = self.src[segment].to_string();
        let mut sub = Builder::new(&text, doc_location, ".", self.definitions, self.definitions, false);
        let src = Rc::clone(&sub.src);
        if let Some(doc) = Document::parse(&src) {
            for block in doc.root().children().into_iter().filter(|b| b.kind() == "paragraph") {
                let Some(r) = sub.local_range(block) else { continue };
                if r.start < sub.content_start || r.start >= sub.content_end {
                    continue;
                }
                for child in block.children() {
                    sub.visit_inline(child, 0);
                }
            }
        }
        self.layout.styles.extend(sub.layout.styles.into_iter().filter(|s| !s.range.is_empty()));
        self.layout.markers.extend(sub.layout.markers);
        self.layout.spell_exempt.extend(sub.layout.spell_exempt);
    }

    /// Visit one inline node; returns its end offset in the parsed text (or None).
    fn visit_inline(&mut self, node: Node, depth: usize) -> Option<usize> {
        if depth >= MAX_DEPTH {
            return None;
        }
        let kind = node.kind();
        let Some(r) = self.local_range(node) else {
            for child in node.children() {
                self.visit_inline(child, depth + 1);
            }
            return None;
        };
        match kind {
            "emph" | "strong" | "strikethrough" => {
                let delimiters: &[u8] = if kind == "strikethrough" { b"~" } else { b"*_" };
                let count = match kind {
                    "emph" => 1,
                    "strong" => 2,
                    _ => self.tilde_run(r.start),
                };
                let style = match kind {
                    "emph" => Style::Emphasis,
                    "strong" => Style::Strong,
                    _ => Style::Strikethrough,
                };
                let mut span = r.clone();
                // Nested runs ("***x***"): cmark gives the inner node the outer
                // node's range. Step inside delimiters an enclosing node claimed.
                let mut inset = 0;
                while inset < 3 && span.len() > 2 && self.claimed[span.start] && self.claimed[span.end - 1] {
                    span = span.start + 1..span.end - 1;
                    inset += 1;
                }
                // cmark occasionally reports the end a character short (after
                // astral characters); allow a small bounded repair, nothing more.
                let mut repair = 0;
                while repair < 3
                    && !(span.end >= count && self.is_run(&(span.end - count..span.end), delimiters))
                    && span.end < self.len()
                {
                    span.end += 1;
                    repair += 1;
                }
                let valid = span.len() >= 2 * count && span.end >= count;
                let open = span.start..span.start + count;
                let close = span.end.saturating_sub(count)..span.end;
                if valid
                    && self.is_run(&open, delimiters)
                    && self.is_run(&close, delimiters)
                    && !self.is_claimed(&open)
                    && !self.is_claimed(&close)
                {
                    let unit = self.doc_range(&span);
                    let inner = self.doc_range(&(span.start + count..span.end - count));
                    self.layout.styles.push(StyleRun { range: inner, style });
                    self.add_marker(open, unit.clone(), false);
                    self.add_marker(close, unit, false);
                } else {
                    // Styled, nothing hidden.
                    self.layout.styles.push(StyleRun { range: self.doc_range(&r), style });
                }
                for child in node.children() {
                    self.visit_inline(child, depth + 1);
                }
            }
            "code" => self.visit_code_span(&r),
            "link" => self.visit_link(node, &r, depth),
            "image" | "html_inline" => {
                let style = if kind == "image" { Style::Image } else { Style::Html };
                let doc = self.doc_range(&r);
                self.layout.styles.push(StyleRun { range: doc.clone(), style });
                self.layout.spell_exempt.push(doc);
            }
            _ => {
                for child in node.children() {
                    self.visit_inline(child, depth + 1);
                }
            }
        }
        Some(r.end)
    }

    fn tilde_run(&self, location: usize) -> usize {
        let n = self.src.as_bytes()[location.min(self.len())..].iter().take_while(|&&b| b == b'~').count();
        n.max(1)
    }

    /// cmark's code-span range covers the content only; widen it over the
    /// backtick runs (and the one space of padding cmark strips each side).
    fn visit_code_span(&mut self, content: &Range<usize>) {
        let bytes = self.src.as_bytes();
        let ticks_ending_at = |i: usize| bytes[..i].iter().rev().take_while(|&&b| b == b'`').count();
        let ticks_starting_at = |i: usize| bytes[i.min(bytes.len())..].iter().take_while(|&&b| b == b'`').count();
        // Opening run, with or without one stripped padding space.
        let mut left = content.start;
        let mut count = ticks_ending_at(left);
        if count == 0 && left > 0 && bytes[left - 1] == b' ' {
            left -= 1;
            count = ticks_ending_at(left);
        }
        let mut right = content.end;
        if ticks_starting_at(right) != count && right < bytes.len() && bytes[right] == b' ' {
            right += 1;
        }
        let doc_content = self.doc_range(content);
        if count == 0 || ticks_starting_at(right) != count {
            self.layout.styles.push(StyleRun { range: doc_content.clone(), style: Style::Code });
            self.layout.spell_exempt.push(doc_content);
            return;
        }
        let (open, close) = (left - count, right + count);
        let unit = self.doc_range(&(open..close));
        self.layout.styles.push(StyleRun { range: doc_content, style: Style::Code });
        self.layout.spell_exempt.push(unit.clone());
        self.add_marker(open..content.start, unit.clone(), false);
        self.add_marker(content.end..close, unit, false);
    }

    fn visit_link(&mut self, node: Node, raw: &Range<usize>, depth: usize) {
        let url = node.url();
        let r = raw.clone();
        let first = if r.is_empty() { 0 } else { self.byte(r.start) };
        let last = if r.is_empty() { 0 } else { self.byte(r.end - 1) };
        match first {
            b'<' if last == b'>' => {
                // Angle autolink.
                if r.len() < 2 {
                    return;
                }
                let unit = self.doc_range(&r);
                let inner = self.doc_range(&(r.start + 1..r.end - 1));
                self.layout.styles.push(StyleRun { range: inner, style: Style::Autolink { url } });
                self.layout.spell_exempt.push(unit.clone());
                self.add_marker(r.start..r.start + 1, unit.clone(), false);
                self.add_marker(r.end - 1..r.end, unit, false);
            }
            b'[' => {
                // Inline or reference link.
                let mut label_end = r.start + 1;
                for child in node.children() {
                    if let Some(end) = self.visit_inline(child, depth + 1) {
                        label_end = label_end.max(end);
                    }
                }
                let mut close = label_end;
                while close < r.end && self.byte(close) != b']' {
                    close += 1;
                }
                if close >= r.end {
                    return;
                }
                let tail_text = &self.src[close..r.end];
                let well_formed = tail_text == "]"
                    || (tail_text.starts_with("](") && tail_text.ends_with(')'))
                    || (tail_text.starts_with("][") && tail_text.ends_with(']'));
                if !well_formed {
                    return;
                }
                let unit = self.doc_range(&r);
                let label = self.doc_range(&(r.start + 1..close));
                self.layout.styles.push(StyleRun { range: label, style: Style::Link { url } });
                self.add_marker(r.start..r.start + 1, unit.clone(), false);
                let tail = close..r.end;
                self.add_marker(tail.clone(), unit, false);
                if tail.len() > 1 {
                    self.layout.spell_exempt.push(self.doc_range(&tail));
                }
            }
            _ => {
                // Extension autolink (www.…, bare URL, email): cmark's range
                // starts one character early. Locate the link text itself.
                let shown = plain_text(node, 0);
                if shown.is_empty() {
                    return;
                }
                let search = r.start..(r.end + 1).min(self.len());
                let hay = &self.src.as_bytes()[search.clone()];
                let Some(at) = hay.windows(shown.len()).position(|w| w == shown.as_bytes()) else { return };
                let found = self.doc_range(&(search.start + at..search.start + at + shown.len()));
                self.layout.styles.push(StyleRun { range: found.clone(), style: Style::Autolink { url } });
                self.layout.spell_exempt.push(found);
            }
        }
    }
}

fn plain_text(node: Node, depth: usize) -> String {
    if depth >= MAX_DEPTH {
        return String::new();
    }
    match node.kind() {
        "text" | "code" => node.literal(),
        "softbreak" | "linebreak" => " ".to_string(),
        _ => node.children().into_iter().map(|c| plain_text(c, depth + 1)).collect(),
    }
}

fn contains_hard_break(node: Node, depth: usize) -> bool {
    if depth >= MAX_DEPTH {
        return false;
    }
    node.children().into_iter().any(|c| c.kind() == "linebreak" || contains_hard_break(c, depth + 1))
}

// MARK: Diff

impl Layout {
    /// The smallest range of the NEW text whose styling differs between `old`
    /// (the layout before an edit) and `self` (a full parse after it).
    ///
    /// Entries wholly before the edit must match unchanged; entries wholly
    /// after it must match shifted by `delta`. Whatever lies between the first
    /// mismatch from the front and the last mismatch from the back, plus the
    /// edited text itself, needs restyling. Exact by construction: both
    /// layouts are full parses, so this only bounds the work, never the truth.
    pub fn changed_range(&self, old: &Layout, edit: Range<usize>, delta: isize) -> Range<usize> {
        let mut bounds = Bounds { start: edit.start, end: edit.end.wrapping_add_signed(delta), edit, delta };
        bounds.widen(&old.styles, &self.styles, |r| r.range.clone(), |o, n, d| {
            o.style == n.style && shifted(&o.range, d) == n.range
        });
        bounds.widen(&old.markers, &self.markers, |m| m.unit.clone(), |o, n, d| {
            shifted(&o.range, d) == n.range && shifted(&o.unit, d) == n.unit && o.collapses_line == n.collapses_line
        });
        bounds.widen(&old.spell_exempt, &self.spell_exempt, |r| r.clone(), |o, n, d| shifted(o, d) == *n);
        bounds.widen(&old.list_items, &self.list_items, |l| l.marker.clone(), |o, n, d| {
            shifted(&o.marker, d) == n.marker
                && shifted(&o.bullet, d) == n.bullet
                && o.level == n.level
                && o.ordered == n.ordered
                && o.task == n.task
                && o.checkbox.as_ref().map(|c| shifted(c, d)) == n.checkbox
        });
        bounds.widen(&old.quote_lines, &self.quote_lines, |q| q.prefix.clone(), |o, n, d| {
            shifted(&o.prefix, d) == n.prefix && o.level == n.level
        });
        bounds.widen(&old.tables, &self.tables, |t| t.range.clone(), |o, n, d| {
            shifted(&o.range, d) == n.range
                && o.alignments == n.alignments
                && o.rows.len() == n.rows.len()
                && o.rows.iter().zip(&n.rows).all(|(a, b)| {
                    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| shifted(x, d) == *y)
                })
        });
        bounds.widen(&old.block_images, &self.block_images, |i| i.range.clone(), |o, n, d| {
            shifted(&o.range, d) == n.range && o.url == n.url && o.alt == n.alt
        });
        let old_breaks: Vec<Range<usize>> = old.soft_breaks.iter().map(|&b| b..b + 1).collect();
        let new_breaks: Vec<Range<usize>> = self.soft_breaks.iter().map(|&b| b..b + 1).collect();
        bounds.widen(&old_breaks, &new_breaks, |r| r.clone(), |o, n, d| shifted(o, d) == *n);
        bounds.widen(&old.code_blocks, &self.code_blocks, |c| c.range.clone(), |o, n, d| {
            shifted(&o.range, d) == n.range && shifted(&o.body, d) == n.body
        });
        let start = bounds.start.min(self.length);
        let end = bounds.end.max(start).min(self.length);
        start..end
    }
}

/// The range `changed_range` is growing, and the edit it grows from.
struct Bounds {
    edit: Range<usize>,
    delta: isize,
    start: usize,
    end: usize,
}

impl Bounds {
    fn widen<T>(&mut self, old: &[T], new: &[T], range: impl Fn(&T) -> Range<usize>, same: impl Fn(&T, &T, isize) -> bool) {
        // Front: items starting before the edit must be identical.
        let mut i = 0;
        while i < old.len() && i < new.len() && range(&new[i]).start < self.edit.start && same(&old[i], &new[i], 0) {
            i += 1;
        }
        if i < new.len() {
            self.start = self.start.min(range(&new[i]).start);
        }
        if i < old.len() {
            self.start = self.start.min(range(&old[i]).start);
        }
        // Back: items starting after the edit must be identical once shifted.
        let mut j = 0;
        while j < old.len() && j < new.len() {
            let (o, n) = (&old[old.len() - 1 - j], &new[new.len() - 1 - j]);
            if range(o).start < self.edit.end || !same(o, n, self.delta) {
                break;
            }
            j += 1;
        }
        if j < new.len() {
            self.end = self.end.max(range(&new[new.len() - 1 - j]).end);
        }
        if j < old.len() {
            self.end = self.end.max(range(&old[old.len() - 1 - j]).end.wrapping_add_signed(self.delta));
        }
    }
}

// MARK: Review markup

/// Every anchor and thread has an "[^rv-" ref or label: without one there is
/// nothing to fold, and the review parse is skipped.
pub fn may_have_review_markup(text: &str) -> bool {
    text.contains("[^rv-")
}

/// Review markup inside a heading's rendered title: anchors keep their text
/// (a substitution its new side), refs go. Hand-rolled
/// `\{~~(?:.*?)~>(.*?)~~\}|\{(?:==|\+\+|--)(.*?)(?:==|\+\+|--)\}|\[\^rv-[a-z0-9]+\]`
/// replaced with `$1$2`.
fn strip_title_markup(title: &str) -> String {
    let mut out = String::new();
    let mut i = 0;
    'scan: while i < title.len() {
        let rest = &title[i..];
        if let Some(after) = rest.strip_prefix("{~~") {
            if let Some(arrow) = after.find("~>") {
                let new_side = &after[arrow + 2..];
                if let Some(close) = new_side.find("~~}") {
                    out.push_str(&new_side[..close]);
                    i += 3 + arrow + 2 + close + 3;
                    continue;
                }
            }
        }
        if rest.starts_with("{==") || rest.starts_with("{++") || rest.starts_with("{--") {
            let inner = &rest[3..];
            for k in 0..=inner.len() {
                if !inner.is_char_boundary(k) {
                    continue;
                }
                let tail = &inner[k..];
                if tail.starts_with("==}") || tail.starts_with("++}") || tail.starts_with("--}") {
                    out.push_str(&inner[..k]);
                    i += 3 + k + 3;
                    continue 'scan;
                }
            }
        }
        if let Some(after) = rest.strip_prefix("[^rv-") {
            let id = after.bytes().take_while(|b| b.is_ascii_digit() || b.is_ascii_lowercase()).count();
            if id > 0 && after.as_bytes().get(id) == Some(&b']') {
                i += 5 + id + 1;
                continue;
            }
        }
        let c = rest.chars().next().expect("non-empty rest");
        out.push(c);
        i += c.len_utf8();
    }
    out
}

impl Layout {
    /// Fold review markup into the layout. cmark knows nothing of it: with
    /// footnotes off it reads a `[^rv-…]` ref as a link and a thread as a
    /// paragraph, and `{~~a~>b~~}` holds a strikethrough. Whatever cmark made
    /// of the markup's own characters goes; the review spans replace it.
    pub fn fold(&mut self, review: Review) {
        if review.anchors.is_empty() && review.threads.is_empty() {
            return;
        }
        let spans = review_spans::spans(&review);
        let anchors: Vec<Range<usize>> = review.anchors.iter().map(|a| a.range.clone()).collect();
        let syntax: Vec<Range<usize>> = spans
            .iter()
            .filter(|s| s.is_hidden() || s.role == SpanRole::PointMarker)
            .map(|s| s.range.clone())
            .collect();
        let refs: Vec<Range<usize>> = spans
            .iter()
            .filter(|s| matches!(s.role, SpanRole::Ref | SpanRole::PointMarker))
            .map(|s| s.range.clone())
            .collect();
        let threads: Vec<Range<usize>> =
            spans.iter().filter(|s| s.role == SpanRole::Definition).map(|s| s.range.clone()).collect();
        let opaque: Vec<Range<usize>> = refs.iter().chain(&threads).cloned().collect();
        self.review = Some(review);

        // A style goes if it is cmark's reading of a ref or thread (inside one,
        // or straddling its edge), or sits inside an anchor across its syntax
        // (the strikethrough cmark sees in "{~~a~~}"). Emphasis, a heading or a
        // link around a whole anchor stays.
        self.styles.retain(|run| {
            let goes = opaque.iter().any(|o| meets(o, &run.range) && !(encloses(&run.range, o) && run.range != *o))
                || (syntax.iter().any(|s| meets(s, &run.range)) && anchors.iter().any(|a| encloses(a, &run.range)));
            !goes
        });
        let hiding: Vec<Range<usize>> = syntax.iter().chain(&threads).cloned().collect();
        self.markers.retain(|m| {
            !(hiding.iter().any(|h| meets(h, &m.range)) || threads.iter().any(|t| meets(t, &m.unit)))
        });
        for heading in &mut self.headings {
            if anchors.iter().any(|a| meets(a, &heading.range)) {
                heading.title = strip_title_markup(&heading.title);
            }
        }
        let in_thread = |r: &Range<usize>| threads.iter().any(|t| meets(t, r));
        self.list_items.retain(|item| !in_thread(&item.marker));
        self.quote_lines.retain(|line| !in_thread(&line.prefix));
        self.block_images.retain(|image| !opaque.iter().any(|o| meets(o, &image.range)));
        self.tables.retain(|table| !in_thread(&table.range));
        self.code_blocks.retain(|block| !in_thread(&block.range));
        self.headings.retain(|heading| !in_thread(&heading.range));
        self.soft_breaks.retain(|&b| !threads.iter().any(|t| t.contains(&b)));

        let mut previous: Option<SpanRole> = None;
        for span in &spans {
            let role = span.role;
            let range = span.range.clone();
            let prior = previous.replace(role);
            if range.is_empty() {
                continue;
            }
            if span.is_spelling_exempt() {
                self.spell_exempt.push(range.clone());
            }
            let unit = || anchors.iter().find(|a| encloses(a, &range)).cloned();
            match role {
                SpanRole::Definition => {
                    self.markers.push(Marker { range: range.clone(), unit: range.clone(), collapses_line: true });
                }
                SpanRole::Delimiter if prior == Some(SpanRole::SubstitutionOld) && range.len() == 2 => {
                    // "~>": the '>' stays, clear and unstyled, as the gap between
                    // the struck old text and the underlined new.
                    let Some(unit) = unit() else { continue };
                    self.markers.push(Marker { range: range.start..range.start + 1, unit, collapses_line: false });
                    self.styles.push(StyleRun {
                        range: range.start + 1..range.start + 2,
                        style: Style::Review { role: SpanRole::Delimiter, id: span.id.clone() },
                    });
                }
                SpanRole::Delimiter | SpanRole::Ref => {
                    let Some(unit) = unit() else { continue };
                    self.markers.push(Marker { range: range.clone(), unit, collapses_line: false });
                }
                SpanRole::PointMarker => {
                    // The "[" stays, small and clear, to carry the drawn marker.
                    self.styles.push(StyleRun {
                        range: range.start..range.start + 1,
                        style: Style::Review { role: SpanRole::PointMarker, id: span.id.clone() },
                    });
                    if range.len() > 1 {
                        self.markers.push(Marker {
                            range: range.start + 1..range.end,
                            unit: range.clone(),
                            collapses_line: false,
                        });
                    }
                }
                SpanRole::Highlight
                | SpanRole::Insertion
                | SpanRole::Deletion
                | SpanRole::SubstitutionOld
                | SpanRole::SubstitutionNew => {
                    self.styles.push(StyleRun { range, style: Style::Review { role, id: span.id.clone() } });
                }
            }
        }
        // Source order keeps `changed_range`'s front and back scans exact.
        self.markers.sort_by_key(|m| m.range.start);
        self.styles.sort_by_key(|s| s.range.start);
        self.spell_exempt.sort_by_key(|r| r.start);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_map_ascii_positions() {
        let map = SourceMap::new("ab\ncd\n");
        assert_eq!(map.offset(1, 1), Some(0));
        assert_eq!(map.offset(2, 2), Some(4));
        assert_eq!(map.range(2, 1, 2, 2), Some(3..5));
    }

    #[test]
    fn source_map_snaps_to_character_boundaries() {
        // "é" is 2 bytes, "😀" is 4.
        let map = SourceMap::new("é😀x\n");
        assert_eq!(map.offset(1, 1), Some(0));
        assert_eq!(map.offset(1, 3), Some(2));
        assert_eq!(map.offset(1, 7), Some(6));
        assert_eq!(map.range(1, 3, 1, 6), Some(2..6));
        // A position naming a continuation byte snaps to its character.
        assert_eq!(map.offset(1, 4), Some(2));
        assert_eq!(map.end_offset(1, 4), Some(6));
    }

    #[test]
    fn source_map_column_zero_is_end_of_previous_line() {
        assert_eq!(SourceMap::new("ab\ncd\n").end_offset(2, 0), Some(3));
    }

    #[test]
    fn source_map_missing_positions_are_none() {
        let map = SourceMap::new("ab\n");
        assert_eq!(map.offset(0, 0), None);
        assert_eq!(map.offset(9, 1), None);
        assert_eq!(map.range(0, 0, 0, 0), None);
    }

    #[test]
    fn definitions_match_the_swift_pattern() {
        let text = "[r]: http://r.s\n   [^x]: y\n    [no]: indent\n[]: empty\n[a] : space\n[b]:\nend";
        let found: Vec<String> = definitions(text).into_iter().map(|d| d.text).collect();
        assert_eq!(found, ["[r]: http://r.s", "   [^x]: y", "[b]:"]);
    }

    #[test]
    fn title_markup_is_stripped() {
        assert_eq!(strip_title_markup("Title {==two==}[^rv-a1b2] {~~old~>new~~}[^rv-c3d4]"), "Title two new");
        assert_eq!(strip_title_markup("a {==b++} c"), "a b c");
        assert_eq!(strip_title_markup("plain [^rv-] é"), "plain [^rv-] é");
    }
}
