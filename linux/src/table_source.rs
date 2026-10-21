//! Edits to a GFM table as edits of its Markdown source. A port of
//! `TableSource.swift`.
//!
//! Typing in a cell edits that cell's source in place (padding untouched,
//! so diffs stay small); structural changes (rows, columns, alignment)
//! rewrite the whole table neatly padded.

use std::ops::Range;

use unicode_segmentation::UnicodeSegmentation;

use crate::layout::{Alignment, Table};

/// A replacement of `range` in the document with `insert`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Edit {
    pub range: Range<usize>,
    pub insert: String,
}

/// A cell's text as the grid edits it: its source, escapes included.
pub fn cell_text<'a>(table: &Table, row: usize, column: usize, text: &'a str) -> &'a str {
    table.rows.get(row).and_then(|r| r.get(column)).map_or("", |c| &text[c.clone()])
}

/// Map an edit of one cell's text (`range` in the cell, `insert`) to an edit
/// of the document. A typed "|" is escaped, so it can't split the cell.
pub fn cell_edit(table: &Table, row: usize, column: usize, range: Range<usize>, insert: &str) -> Edit {
    let cell = &table.rows[row][column];
    Edit { range: cell.start + range.start..cell.start + range.end, insert: insert.replace('|', "\\|") }
}

/// Rewrite the table after `change` edits its cells (header row first) and
/// column alignments. Rows are padded to the widest row first.
pub fn reformat(table: &Table, text: &str, change: impl FnOnce(&mut Vec<Vec<String>>, &mut Vec<Alignment>)) -> Edit {
    let mut cells: Vec<Vec<String>> = table.rows.iter().map(|r| r.iter().map(|c| text[c.clone()].to_string()).collect()).collect();
    let mut alignments = table.alignments.clone();
    let columns = alignments.len().max(cells.iter().map(Vec::len).max().unwrap_or(0));
    for row in &mut cells {
        row.resize(columns, String::new());
    }
    alignments.resize(columns, Alignment::None);
    change(&mut cells, &mut alignments);
    Edit { range: table.range.clone(), insert: render(&cells, &alignments) }
}

fn width(s: &str) -> usize {
    s.graphemes(true).count()
}

/// The table as neatly padded Markdown, no final newline.
pub fn render(cells: &[Vec<String>], alignments: &[Alignment]) -> String {
    let columns = alignments.len().max(cells.iter().map(Vec::len).max().unwrap_or(0));
    let rows: Vec<Vec<&str>> =
        cells.iter().map(|r| (0..columns).map(|c| r.get(c).map_or("", String::as_str)).collect()).collect();
    let align = |c: usize| alignments.get(c).copied().unwrap_or(Alignment::None);
    let widths: Vec<usize> = (0..columns).map(|c| rows.iter().map(|r| width(r[c])).max().unwrap_or(0).max(3)).collect();
    let pad = |s: &str, w: usize, a: Alignment| {
        let gap = w.saturating_sub(width(s));
        match a {
            Alignment::Right => format!("{}{s}", " ".repeat(gap)),
            Alignment::Center => format!("{}{s}{}", " ".repeat(gap / 2), " ".repeat(gap - gap / 2)),
            _ => format!("{s}{}", " ".repeat(gap)),
        }
    };
    let line = |row: &[&str]| {
        let cells: Vec<String> = (0..columns).map(|c| pad(row[c], widths[c], align(c))).collect();
        format!("| {} |", cells.join(" | "))
    };
    let delimiter: Vec<String> = (0..columns)
        .map(|c| {
            let w = widths[c];
            match align(c) {
                Alignment::Left => format!(":{}", "-".repeat(w - 1)),
                Alignment::Right => format!("{}:", "-".repeat(w - 1)),
                Alignment::Center => format!(":{}:", "-".repeat(w - 2)),
                Alignment::None => "-".repeat(w),
            }
        })
        .collect();
    let Some(header) = rows.first() else { return String::new() };
    let mut out = vec![line(header), format!("| {} |", delimiter.join(" | "))];
    out.extend(rows[1..].iter().map(|r| line(r)));
    out.join("\n")
}

/// The structural commands, as on macOS.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    InsertRowAbove,
    InsertRowBelow,
    InsertColumnLeft,
    InsertColumnRight,
    DeleteRow,
    DeleteColumn,
    AlignLeft,
    AlignCenter,
    AlignRight,
}

impl Command {
    pub const ALL: [Command; 9] = [
        Command::InsertRowAbove,
        Command::InsertRowBelow,
        Command::InsertColumnLeft,
        Command::InsertColumnRight,
        Command::DeleteRow,
        Command::DeleteColumn,
        Command::AlignLeft,
        Command::AlignCenter,
        Command::AlignRight,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Command::InsertRowAbove => "Insert Row Above",
            Command::InsertRowBelow => "Insert Row Below",
            Command::InsertColumnLeft => "Insert Column Left",
            Command::InsertColumnRight => "Insert Column Right",
            Command::DeleteRow => "Delete Row",
            Command::DeleteColumn => "Delete Column",
            Command::AlignLeft => "Align Column Left",
            Command::AlignCenter => "Align Column Center",
            Command::AlignRight => "Align Column Right",
        }
    }

    /// The action name, under the "table." group.
    pub fn action(self) -> &'static str {
        match self {
            Command::InsertRowAbove => "insert-row-above",
            Command::InsertRowBelow => "insert-row-below",
            Command::InsertColumnLeft => "insert-column-left",
            Command::InsertColumnRight => "insert-column-right",
            Command::DeleteRow => "delete-row",
            Command::DeleteColumn => "delete-column",
            Command::AlignLeft => "align-left",
            Command::AlignCenter => "align-center",
            Command::AlignRight => "align-right",
        }
    }

    /// The edit this command makes from cell (`row`, `column`); `None` when it
    /// changes nothing (the header row can't go, nor the last column or body
    /// row).
    pub fn edit(self, table: &Table, text: &str, row: usize, column: usize) -> Option<Edit> {
        let blank = |n: usize| vec![String::new(); n];
        let rows = table.rows.len();
        let columns = table.alignments.len().max(table.rows.iter().map(Vec::len).max().unwrap_or(0));
        let refuse = match self {
            Command::DeleteRow => row == 0 || rows <= 2,
            Command::DeleteColumn => columns <= 1,
            _ => false,
        };
        if refuse {
            return None;
        }
        Some(reformat(table, text, |cells, alignments| match self {
            Command::InsertRowAbove => cells.insert(row.max(1), blank(columns)),
            Command::InsertRowBelow => cells.insert((row + 1).min(cells.len()), blank(columns)),
            Command::InsertColumnLeft | Command::InsertColumnRight => {
                let at = if self == Command::InsertColumnLeft { column } else { column + 1 };
                for r in cells.iter_mut() {
                    r.insert(at.min(r.len()), String::new());
                }
                alignments.insert(at.min(alignments.len()), Alignment::None);
            }
            Command::DeleteRow => {
                cells.remove(row);
            }
            Command::DeleteColumn => {
                for r in cells.iter_mut().filter(|r| column < r.len()) {
                    r.remove(column);
                }
                if column < alignments.len() {
                    alignments.remove(column);
                }
            }
            Command::AlignLeft | Command::AlignCenter | Command::AlignRight => {
                if let Some(a) = alignments.get_mut(column) {
                    *a = match self {
                        Command::AlignLeft => Alignment::Left,
                        Command::AlignCenter => Alignment::Center,
                        _ => Alignment::Right,
                    };
                }
            }
        }))
    }
}
