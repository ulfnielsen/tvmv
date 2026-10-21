//! Applies a `Layout` to the GtkTextBuffer as tags, limited to one range.
//! A port of `Sources/tvmv/DocumentStyler.swift`.
//!
//! Every style is one named tag, created once; a theme change edits the tags'
//! properties and GTK relays out by itself. Paragraph indents (lists, quotes)
//! are tags too, one per distinct indent, cached. A tag's left margin replaces
//! the view's rather than adding to it, so indent tags carry the column's
//! offset and are updated when the column moves.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::ops::Range;

use gtk4::prelude::*;
use gtk4::{TextBuffer, TextTag, pango};

use crate::layout::{Layout, Style};
use crate::offsets::SourceText;
use crate::review_spans::SpanRole;

use super::theme::NativeTheme;

/// Where a list item's text starts at nesting `level`; its bullet sits in the em before.
pub fn list_indent(level: usize, em: f64) -> f64 {
    (level as f64 + 1.0) * 1.6 * em
}

/// Where quoted text starts at quote depth `level`; one rule per level sits to its left.
pub fn quote_indent(level: usize, em: f64) -> f64 {
    level as f64 * 1.2 * em
}

pub struct Tags {
    pub hidden: TextTag,
    pub blank: TextTag,
    pub code_line: TextTag,
    pub code_first: TextTag,
    pub code_last: TextTag,
    pub quote: TextTag,
    pub headings: Vec<TextTag>,
    pub code_block: TextTag,
    pub code: TextTag,
    pub raw: TextTag,
    pub emphasis: TextTag,
    pub strong: TextTag,
    pub strike: TextTag,
    pub link: TextTag,
    pub highlight: TextTag,
    pub insertion: TextTag,
    pub deletion: TextTag,
    /// A point comment's "[": clear, holding the room its marker is drawn in.
    pub point_carrier: TextTag,
    /// The '>' of "~>": the gap between old and new.
    pub gap: TextTag,
}

impl Tags {
    fn new(buffer: &TextBuffer) -> Tags {
        let table = buffer.tag_table();
        // Later tags win where properties conflict: paragraph shapes first,
        // then the character styles, the hiding last.
        let add = |name: &str| {
            let tag = TextTag::new(Some(name));
            table.add(&tag);
            tag
        };
        Tags {
            blank: add("blank"),
            code_line: add("code-line"),
            code_first: add("code-first"),
            code_last: add("code-last"),
            quote: add("quote"),
            headings: (1..=6).map(|l| add(&format!("h{l}"))).collect(),
            code_block: add("code-block"),
            code: add("code"),
            raw: add("raw"),
            emphasis: add("emphasis"),
            strong: add("strong"),
            strike: add("strike"),
            link: add("link"),
            highlight: add("highlight"),
            insertion: add("insertion"),
            deletion: add("deletion"),
            point_carrier: add("point-carrier"),
            gap: add("gap"),
            hidden: add("hidden"),
        }
    }

    /// Set every tag's properties for `theme`.
    fn theme(&self, theme: &NativeTheme) {
        let em = theme.em();
        let px = |v: f64| v.round() as i32;
        self.hidden.set_invisible(true);
        // app.css: a blank line between blocks is the 1em paragraph margin.
        self.blank.set_line_height(1.0);
        self.code_line.set_line_height(1.15);
        self.code_first.set_pixels_above_lines(px(em * 0.7));
        self.code_last.set_pixels_below_lines(px(em * 1.1));
        self.quote.set_foreground_rgba(Some(&theme.ink_soft));
        for (i, tag) in self.headings.iter().enumerate() {
            tag.set_scale(NativeTheme::heading_scale(i + 1));
            tag.set_weight(400);
            tag.set_line_height(1.25);
            tag.set_pixels_above_lines(px(em * 0.6));
        }
        for tag in [&self.code_block, &self.code] {
            tag.set_family(Some(&theme.mono_family));
            tag.set_scale(NativeTheme::MONO_SCALE);
        }
        self.raw.set_family(Some(&theme.mono_family));
        self.raw.set_scale(NativeTheme::MONO_SCALE);
        self.raw.set_foreground_rgba(Some(&theme.muted));
        self.emphasis.set_style(pango::Style::Italic);
        self.strong.set_weight(700);
        self.strike.set_strikethrough(true);
        self.link.set_foreground_rgba(Some(&theme.accent));
        self.link.set_underline(pango::Underline::Single);
        self.highlight.set_background_rgba(Some(&theme.review_highlight));
        self.insertion.set_foreground_rgba(Some(&theme.review_insert));
        self.insertion.set_underline(pango::Underline::Single);
        self.deletion.set_foreground_rgba(Some(&theme.review_delete));
        self.deletion.set_strikethrough(true);
        // "Clear" is paper: GTK draws a transparent foreground opaque.
        self.point_carrier.set_foreground_rgba(Some(&theme.paper));
        self.point_carrier.set_letter_spacing(px(em * 0.25 * pango::SCALE as f64));
        self.gap.set_foreground_rgba(Some(&theme.paper));
        self.gap.set_scale(0.5);
    }
}

pub struct Styler {
    pub tags: Tags,
    buffer: TextBuffer,
    /// Indent tags by (head indent, first-line indent) in pixels from the column.
    indents: RefCell<HashMap<(i32, i32), TextTag>>,
    /// The column's x: indent tags' margins are relative to the view's edge.
    column_x: Cell<i32>,
    /// Marker widths by text: markers repeat ("- ", "1. "), and measuring
    /// one builds a Pango layout.
    widths: RefCell<HashMap<String, i32>>,
}

/// The line containing byte `at`, with its newline.
fn line_range(text: &str, at: usize) -> Range<usize> {
    let at = at.min(text.len());
    let bytes = text.as_bytes();
    let start = bytes[..at].iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
    let end = bytes[at..].iter().position(|&b| b == b'\n').map_or(text.len(), |i| at + i + 1);
    start..end
}

/// Ranges sorted for overlap queries: short ones by start, long ones (a
/// code block, a collapsed thread) kept apart and always checked.
#[derive(Clone, Debug, Default)]
pub struct SpanIndex {
    short: Vec<(usize, usize, usize)>,
    long: Vec<(usize, usize, usize)>,
}

const LONG: usize = 4096;

impl SpanIndex {
    pub fn new<'a>(ranges: impl Iterator<Item = &'a Range<usize>>) -> SpanIndex {
        let mut index = SpanIndex::default();
        for (i, r) in ranges.enumerate() {
            let entry = (r.start, r.end, i);
            if r.len() > LONG { index.long.push(entry) } else { index.short.push(entry) }
        }
        index.short.sort_unstable();
        index
    }

    /// Indices of the ranges that overlap `range` (or are empty inside it).
    pub fn query(&self, range: &Range<usize>) -> impl Iterator<Item = usize> + '_ {
        let from = self.short.partition_point(|&(start, _, _)| start + LONG < range.start);
        let (lo, hi) = (range.start, range.end);
        self.short[from..]
            .iter()
            .take_while(move |&&(start, _, _)| start < hi)
            .chain(self.long.iter())
            .filter(move |&&(start, end, _)| end > lo && start < hi)
            .map(|&(_, _, i)| i)
    }
}

/// Something the view hides unless its unit is revealed.
#[derive(Clone, Debug)]
pub struct Hideable {
    pub range: Range<usize>,
    pub unit: Range<usize>,
}

/// A layout with the indexes the styler and the view query it through.
/// Built where the parse runs, off the main thread for large documents.
#[derive(Clone, Debug, Default)]
pub struct Prepared {
    pub layout: Layout,
    pub styles: SpanIndex,
    pub hideables: Vec<Hideable>,
    pub hidden_index: SpanIndex,
}

impl Prepared {
    pub fn new(layout: Layout) -> Prepared {
        let styles = SpanIndex::new(layout.styles.iter().map(|s| &s.range));
        // Markers and container prefixes: hidden unless their unit is revealed.
        let hideables: Vec<Hideable> = layout
            .markers
            .iter()
            .map(|m| Hideable { range: m.range.clone(), unit: m.unit.clone() })
            .chain(layout.quote_lines.iter().map(|q| Hideable { range: q.prefix.clone(), unit: q.prefix.clone() }))
            .chain(layout.list_items.iter().map(|l| Hideable { range: l.marker.clone(), unit: l.marker.clone() }))
            .filter(|h| !h.range.is_empty())
            .collect();
        let hidden_index = SpanIndex::new(hideables.iter().map(|h| &h.range));
        Prepared { layout, styles, hideables, hidden_index }
    }

    pub fn parse(text: &str) -> Prepared {
        Prepared::new(crate::layout::parse(text))
    }
}

/// Items in source order whose `key` overlaps `range` (binary search on start,
/// for items no longer than a line).
fn in_lines<'a, T>(items: &'a [T], range: &Range<usize>, key: impl Fn(&T) -> usize) -> &'a [T] {
    let from = items.partition_point(|i| key(i) + LONG < range.start);
    let to = items.partition_point(|i| key(i) < range.end);
    &items[from..to.max(from)]
}

impl Styler {
    pub fn new(buffer: &TextBuffer, theme: &NativeTheme) -> Styler {
        let tags = Tags::new(buffer);
        tags.theme(theme);
        Styler {
            tags,
            buffer: buffer.clone(),
            indents: RefCell::new(HashMap::new()),
            column_x: Cell::new(0),
            widths: RefCell::new(HashMap::new()),
        }
    }

    pub fn set_theme(&self, theme: &NativeTheme) {
        self.tags.theme(theme);
        self.widths.borrow_mut().clear();
    }

    /// The column moved: indent tags follow it.
    pub fn set_column_x(&self, x: i32) {
        if self.column_x.replace(x) == x {
            return;
        }
        for (&(head, first), tag) in self.indents.borrow().iter() {
            tag.set_left_margin(x + head);
            tag.set_indent(first);
        }
    }

    fn indent_tag(&self, head: i32, first: i32) -> TextTag {
        self.indents
            .borrow_mut()
            .entry((head, first))
            .or_insert_with(|| {
                let tag = TextTag::new(None);
                tag.set_left_margin(self.column_x.get() + head);
                tag.set_indent(first);
                // Indents set the paragraph's shape: below the character styles.
                self.buffer.tag_table().add(&tag);
                tag.set_priority(0);
                tag
            })
            .clone()
    }

    /// Restyle source range `range` of `source` from `layout`.
    ///
    /// - `fresh`: the range has never been styled, so there is nothing to
    ///   clear first. Clearing looks for the next tag toggle of any tag, and
    ///   in an unstyled stretch that search runs to the end of the buffer.
    /// - `revealed`: whether a reveal unit's markup is currently shown.
    /// - `width`: a string's width in the body font, in pixels.
    #[allow(clippy::too_many_arguments)]
    pub fn apply(
        &self,
        source: &SourceText,
        prepared: &Prepared,
        range: Range<usize>,
        fresh: bool,
        theme: &NativeTheme,
        revealed: &dyn Fn(&Range<usize>) -> bool,
        width: &dyn Fn(&str) -> i32,
    ) {
        let text = source.text();
        let range = range.start.min(text.len())..range.end.min(text.len());
        if range.is_empty() {
            return;
        }
        let b = &self.buffer;
        let iter = |byte: usize| b.iter_at_offset(source.to_buffer(byte));
        let clip = |r: &Range<usize>| {
            let c = r.start.max(range.start)..r.end.min(range.end);
            (!c.is_empty()).then_some(c)
        };
        let tag = |t: &TextTag, r: &Range<usize>| {
            if let Some(c) = clip(r) {
                b.apply_tag(t, &iter(c.start), &iter(c.end));
            }
        };
        if !fresh {
            b.remove_all_tags(&iter(range.start), &iter(range.end));
        }
        let tags = &self.tags;
        let layout = &prepared.layout;
        // The unit a marker belongs to, by where the marker starts or ends.
        let unit_starting = |at: usize| {
            prepared.hidden_index.query(&(at..at + 2)).map(|i| &prepared.hideables[i]).find(|h| h.unit.start == at)
        };
        let unit_ending_at = |at: usize| {
            let probe = at.saturating_sub(1)..at;
            prepared.hidden_index.query(&probe).map(|i| &prepared.hideables[i]).find(|h| h.range.end == at)
        };

        for run in prepared.styles.query(&range).map(|i| &layout.styles[i]) {
            match &run.style {
                Style::Heading { level } => tag(&tags.headings[level.clamp(&1, &6) - 1], &run.range),
                Style::Emphasis => tag(&tags.emphasis, &run.range),
                Style::Strong => tag(&tags.strong, &run.range),
                Style::Strikethrough => tag(&tags.strike, &run.range),
                // The pill behind inline code is drawn by the view: a background
                // would fill the whole 1.7× line height.
                Style::Code => tag(&tags.code, &run.range),
                Style::CodeBlock { .. } => tag(&tags.code_block, &run.range),
                Style::Link { .. } | Style::Autolink { .. } => tag(&tags.link, &run.range),
                Style::Html | Style::Image => tag(&tags.raw, &run.range),
                Style::Review { role, .. } => match role {
                    SpanRole::Highlight => tag(&tags.highlight, &run.range),
                    SpanRole::Insertion | SpanRole::SubstitutionNew => tag(&tags.insertion, &run.range),
                    SpanRole::Deletion | SpanRole::SubstitutionOld => tag(&tags.deletion, &run.range),
                    SpanRole::PointMarker => {
                        let unit = unit_starting(run.range.start).map(|h| &h.unit);
                        if !revealed(unit.unwrap_or(&run.range)) {
                            tag(&tags.point_carrier, &run.range);
                        }
                    }
                    SpanRole::Delimiter => {
                        let unit = unit_ending_at(run.range.start).map(|h| &h.unit);
                        if !revealed(unit.unwrap_or(&run.range)) {
                            tag(&tags.gap, &run.range);
                        }
                    }
                    SpanRole::Ref | SpanRole::Definition => {}
                },
            }
        }

        // Blank lines (outside code) are the gap between blocks.
        let in_code = |at: usize| {
            let i = layout.code_blocks.partition_point(|c| c.range.end <= at);
            layout.code_blocks.get(i).is_some_and(|c| c.range.contains(&at))
        };
        let mut line_start = line_range(text, range.start).start;
        while line_start < range.end && line_start < text.len() {
            let line = line_range(text, line_start);
            if &text[line.clone()] == "\n" && !in_code(line.start) {
                tag(&tags.blank, &line);
            }
            line_start = line.end;
        }

        let first_block = layout.code_blocks.partition_point(|c| c.range.end <= range.start);
        for block in layout.code_blocks[first_block..].iter().take_while(|c| c.range.start < range.end) {
            if block.body.is_empty() || block.body.end <= range.start || block.body.start >= range.end {
                continue;
            }
            let mut line = line_range(text, block.body.start);
            while line.start < block.body.end {
                tag(&tags.code_line, &line);
                if line.start <= block.body.start {
                    tag(&tags.code_first, &line);
                }
                if line.end >= block.body.end {
                    tag(&tags.code_last, &line);
                }
                if line.end >= text.len() {
                    break;
                }
                line = line_range(text, line.end);
            }
        }

        for hideable in prepared.hidden_index.query(&range).map(|i| &prepared.hideables[i]) {
            if !revealed(&hideable.unit) {
                tag(&tags.hidden, &hideable.range);
            }
        }

        // Quotes and lists: the prefix and marker hide and the line indents
        // (the view draws the rule, bullet, number or checkbox in the space).
        // When the markup shows it takes that space instead, so the text
        // stays put.
        let em = theme.em();
        let width = |s: &str| {
            if let Some(&w) = self.widths.borrow().get(s) {
                return w;
            }
            let w = width(s);
            self.widths.borrow_mut().insert(s.to_string(), w);
            w
        };
        let mut indents: HashMap<usize, (f64, f64)> = HashMap::new();
        for quote in in_lines(&layout.quote_lines, &range, |q| q.prefix.start) {
            let line = line_range(text, quote.prefix.start);
            if line.end <= range.start || line.start >= range.end {
                continue;
            }
            tag(&tags.quote, &line);
            let entry = indents.entry(line.start).or_default();
            entry.0 += quote_indent(quote.level, em);
            if revealed(&quote.prefix) {
                entry.1 += width(&text[quote.prefix.clone()]) as f64;
            }
        }
        for item in in_lines(&layout.list_items, &range, |l| l.marker.start) {
            let line = line_range(text, item.marker.start);
            if line.end <= range.start || line.start >= range.end {
                continue;
            }
            let entry = indents.entry(line.start).or_default();
            // The gutter fits the marker as typed ("- [ ] ", "10. "), so it can
            // take the bullet's place without moving the text.
            let gutter_start = list_indent(item.level, em) - 1.6 * em;
            let marker = &text[item.marker.clone()];
            let marker_width = width(marker) as f64;
            // Checked and open boxes share one gutter, so a task list lines up.
            let gutter_width =
                if item.task.is_none() { marker_width } else { width(&marker.replace("[ ]", "[x]")) as f64 };
            entry.0 += list_indent(item.level, em).max(gutter_start + gutter_width);
            if revealed(&item.marker) {
                entry.1 += marker_width;
            }
        }
        for (start, (amount, shown)) in indents {
            let head = amount.round() as i32;
            let first = (amount - shown).max(0.0).round() as i32 - head;
            tag(&self.indent_tag(head, first), &line_range(text, start));
        }
    }
}
