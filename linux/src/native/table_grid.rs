//! A GFM table shown as an editable grid over its hidden source. A port of
//! `TableGridView.swift`.
//!
//! The grid sits on a child anchor before the table's first character; the
//! source stays in the buffer, hidden. Each cell is a small `DocumentView`
//! (the same inline rendering) whose text is the cell's source. Typing in a
//! cell edits that cell's source in the document through the document's own
//! edit path, so there is one undo stack, and the grid refreshes from the
//! re-parsed table. Structural commands rewrite the table neatly
//! (`table_source`).

use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

use gtk4::prelude::*;
use gtk4::{gio, glib};

use crate::layout::{Alignment, Table};
use crate::table_source::Command;

use super::document_view::{CellHooks, CellKey, DocumentView};
use super::theme::NativeTheme;

/// Horizontal and vertical padding inside a cell, as on macOS.
pub const CELL_INSET: (i32, i32) = (7, 5);
pub const MIN_COLUMN_WIDTH: i32 = 48;

pub struct TableGrid {
    pub widget: gtk4::Grid,
    host: Weak<DocumentView>,
    /// The table's start in the host's source, as of the last update.
    pub start: Cell<usize>,
    cells: RefCell<Vec<Vec<Rc<DocumentView>>>>,
    /// Cell texts as of the last update.
    texts: RefCell<Vec<Vec<String>>>,
    theme: RefCell<Option<NativeTheme>>,
    /// The cell whose own edit is being applied: it already shows the text.
    editing: Cell<Option<(usize, usize)>>,
    /// Whether the cells exist. Far from the screen a grid is a placeholder
    /// of about its height: a document can hold thousands of tables, and
    /// every cell is a text view.
    built: Cell<bool>,
    /// The table, kept to build the cells from when the grid comes near.
    table: RefCell<Option<Table>>,
    me: Weak<TableGrid>,
}

impl TableGrid {
    pub fn new(host: &Rc<DocumentView>) -> Rc<TableGrid> {
        let widget = gtk4::Grid::new();
        widget.add_css_class("tvmv-table");
        widget.set_halign(gtk4::Align::Start);
        Rc::new_cyclic(|me| TableGrid {
            widget,
            host: Rc::downgrade(host),
            start: Cell::new(0),
            cells: RefCell::default(),
            texts: RefCell::default(),
            theme: RefCell::default(),
            editing: Cell::new(None),
            built: Cell::new(false),
            table: RefCell::new(None),
            me: me.clone(),
        })
    }

    /// The cells' texts, header row first.
    pub fn cell_texts(&self) -> Vec<Vec<String>> {
        self.cells.borrow().iter().map(|row| row.iter().map(|c| c.text()).collect()).collect()
    }

    pub fn cell(&self, row: usize, column: usize) -> Option<Rc<DocumentView>> {
        self.cells.borrow().get(row)?.get(column).cloned()
    }

    /// The cell with keyboard focus.
    pub fn focused(&self) -> Option<(usize, usize)> {
        self.cells.borrow().iter().enumerate().find_map(|(r, row)| {
            row.iter().position(|c| c.view.has_focus()).map(|c| (r, c))
        })
    }

    pub fn is_built(&self) -> bool {
        self.built.get()
    }

    /// Show `table` of `text`, at most `width` wide. Unbuilt, the grid only
    /// keeps the table and takes about its height (`row_height` a row).
    pub fn update(&self, table: &Table, text: &str, theme: &NativeTheme, width: i32, editable: bool, row_height: i32) {
        self.start.set(table.range.start);
        *self.table.borrow_mut() = Some(table.clone());
        if !self.built.get() {
            self.placeholder(table.rows.len(), row_height, width);
            return;
        }
        self.widget.set_size_request(-1, -1);
        let columns = table.alignments.len().max(table.rows.iter().map(Vec::len).max().unwrap_or(0));
        let texts: Vec<Vec<String>> = table
            .rows
            .iter()
            .map(|row| (0..columns).map(|c| row.get(c).map_or(String::new(), |r| text[r.clone()].to_string())).collect())
            .collect();
        let shape_changed = {
            let cells = self.cells.borrow();
            cells.len() != texts.len() || cells.first().map(Vec::len) != Some(columns)
        };
        if shape_changed || self.theme.borrow().as_ref() != Some(theme) {
            self.rebuild(&texts, &table.alignments, theme, editable);
        } else {
            let alignments_changed = {
                let cells = self.cells.borrow();
                cells.first().is_some_and(|row| {
                    row.iter().enumerate().any(|(c, cell)| cell.view.justification() != justification(table.alignments.get(c)))
                })
            };
            for (r, row) in self.cells.borrow().iter().enumerate() {
                for (c, cell) in row.iter().enumerate() {
                    if alignments_changed {
                        cell.view.set_justification(justification(table.alignments.get(c)));
                    }
                    if self.editing.get() == Some((r, c)) || cell.text() == texts[r][c] {
                        continue;
                    }
                    let caret = cell.selection().start.min(texts[r][c].len());
                    cell.load(texts[r][c].clone());
                    cell.set_caret(caret);
                }
            }
        }
        for cell in self.cells.borrow().iter().flatten() {
            if cell.is_editable() != editable {
                cell.set_editable(editable);
            }
        }
        *self.texts.borrow_mut() = texts;
        *self.theme.borrow_mut() = Some(theme.clone());
        self.layout_cells(width);
    }

    fn rebuild(&self, texts: &[Vec<String>], alignments: &[Alignment], theme: &NativeTheme, editable: bool) {
        let focus = self.focused();
        while let Some(child) = self.widget.first_child() {
            self.widget.remove(&child);
        }
        let mut cell_theme = theme.clone();
        cell_theme.full_width = true;
        cell_theme.padding = CELL_INSET.0 as f64;
        let cells: Vec<Vec<Rc<DocumentView>>> = texts
            .iter()
            .enumerate()
            .map(|(r, row)| {
                row.iter()
                    .enumerate()
                    .map(|(c, value)| {
                        let cell = DocumentView::new(cell_theme.clone());
                        cell.view.add_css_class("tvmv-cell");
                        if r == 0 {
                            cell.view.add_css_class("tvmv-cell-header");
                        }
                        cell.view.set_top_margin(CELL_INSET.1);
                        cell.view.set_bottom_margin(CELL_INSET.1);
                        cell.view.set_justification(justification(alignments.get(c)));
                        cell.view.set_hexpand(false);
                        self.hook(&cell, r, c);
                        cell.load(value.clone());
                        cell.set_editable(editable);
                        self.widget.attach(&cell.view, c as i32, r as i32, 1, 1);
                        cell
                    })
                    .collect()
            })
            .collect();
        *self.cells.borrow_mut() = cells;
        if let Some((r, c)) = focus
            && let Some(cell) = self.cell(r, c)
        {
            cell.view.grab_focus();
        }
    }

    /// Wire cell (`row`, `column`) to the grid: its edits, keys, links and
    /// the table commands in its menu.
    fn hook(&self, cell: &Rc<DocumentView>, row: usize, column: usize) {
        let (grid, edit_grid) = (self.me.clone(), self.me.clone());
        let weak_cell = Rc::downgrade(cell);
        cell.set_cell_hooks(CellHooks {
            on_edit: Box::new(move |range, inserted| {
                if let Some(grid) = edit_grid.upgrade() {
                    grid.cell_did_edit(row, column, range, inserted);
                }
            }),
            on_key: Box::new(move |key| {
                let (Some(grid), Some(cell)) = (grid.upgrade(), weak_cell.upgrade()) else { return false };
                grid.key(&cell, row, column, key)
            }),
        });
        let host = self.host.clone();
        cell.set_on_follow_link(move |url| {
            if let Some(host) = host.upgrade() {
                host.follow_link(url);
            }
        });
        let actions = gio::SimpleActionGroup::new();
        let menu = gio::Menu::new();
        let section = |commands: &[Command]| {
            let part = gio::Menu::new();
            for &command in commands {
                part.append(Some(command.title()), Some(&format!("table.{}", command.action())));
            }
            part
        };
        menu.append_section(None, &section(&Command::ALL[..6]));
        menu.append_section(None, &section(&Command::ALL[6..]));
        for command in Command::ALL {
            let action = gio::SimpleAction::new(command.action(), None);
            let grid = self.me.clone();
            action.connect_activate(move |_, _| {
                if let Some(grid) = grid.upgrade() {
                    grid.perform(command, row, column);
                }
            });
            actions.add_action(&action);
        }
        cell.view.insert_action_group("table", Some(&actions));
        cell.set_extra_menu(Some(menu.upcast()));
    }

    /// Columns take their content's width, scaled down to `width` when the
    /// table is wider than the text column.
    fn layout_cells(&self, width: i32) {
        let cells = self.cells.borrow();
        let Some(first) = cells.first() else { return };
        let mut natural = vec![MIN_COLUMN_WIDTH; first.len()];
        for row in cells.iter() {
            for (c, cell) in row.iter().enumerate() {
                natural[c] = natural[c].max(cell.natural_width() + 2 * CELL_INSET.0 + 2);
            }
        }
        let total: i32 = natural.iter().sum();
        let widths: Vec<i32> = if total <= width || width <= 0 {
            natural
        } else {
            natural.iter().map(|&w| MIN_COLUMN_WIDTH.max(w * width / total)).collect()
        };
        for row in cells.iter() {
            for (c, cell) in row.iter().enumerate() {
                if cell.view.width_request() != widths[c] {
                    cell.view.set_size_request(widths[c], -1);
                }
            }
        }
    }

    /// Create the cells (the grid has come near the screen).
    pub fn build(&self, text: &str, theme: &NativeTheme, width: i32, editable: bool) {
        if self.built.replace(true) {
            return;
        }
        let Some(table) = self.table.borrow().clone() else { return };
        self.update(&table, text, theme, width, editable, 0);
    }

    /// Back to a placeholder (the grid is far from the screen). Not while
    /// one of its cells has focus.
    pub fn unbuild(&self, row_height: i32, width: i32) -> bool {
        if !self.built.get() || self.focused().is_some() {
            return false;
        }
        while let Some(child) = self.widget.first_child() {
            self.widget.remove(&child);
        }
        self.cells.borrow_mut().clear();
        self.texts.borrow_mut().clear();
        *self.theme.borrow_mut() = None;
        self.built.set(false);
        let rows = self.table.borrow().as_ref().map_or(1, |t| t.rows.len());
        self.placeholder(rows, row_height, width);
        true
    }

    /// Take about the room `rows` rows would.
    fn placeholder(&self, rows: usize, row_height: i32, width: i32) {
        self.widget.set_size_request(width.clamp(1, MIN_COLUMN_WIDTH * 8), rows as i32 * row_height + 1);
    }

    /// Height of a row, measured (for placeholders).
    pub fn row_height(&self) -> Option<i32> {
        let rows = self.cells.borrow().len() as i32;
        (self.built.get() && rows > 0 && self.widget.height() > 0).then(|| (self.widget.height() - 1) / rows)
    }

    pub fn set_editable(&self, editable: bool) {
        for cell in self.cells.borrow().iter().flatten() {
            cell.set_editable(editable);
        }
    }

    // MARK: Editing

    fn cell_did_edit(&self, row: usize, column: usize, range: std::ops::Range<usize>, inserted: &str) {
        let Some(host) = self.host.upgrade() else { return };
        self.editing.set(Some((row, column)));
        host.apply_cell_edit(self.start.get(), row, column, range, inserted);
        self.editing.set(None);
        // The cell may now differ from its source (an escaped "|"): resync
        // once its own edit has finished processing.
        let grid = self.me.clone();
        glib::idle_add_local_once(move || {
            let Some(grid) = grid.upgrade() else { return };
            let (Some(cell), Some(source)) =
                (grid.cell(row, column), grid.texts.borrow().get(row).and_then(|r| r.get(column)).cloned())
            else {
                return;
            };
            let shown = cell.text();
            if shown != source {
                let caret = (cell.selection().start + source.len()).saturating_sub(shown.len()).min(source.len());
                cell.load(source);
                cell.set_caret(caret);
            }
        });
    }

    /// Handle `key` in cell (`row`, `column`), as its keystroke would.
    pub fn press(&self, row: usize, column: usize, key: CellKey) -> bool {
        let Some(cell) = self.cell(row, column) else { return false };
        self.key(&cell, row, column, key)
    }

    fn key(&self, cell: &DocumentView, row: usize, column: usize, key: CellKey) -> bool {
        let Some(host) = self.host.upgrade() else { return false };
        match key {
            CellKey::Next | CellKey::Previous | CellKey::Down => {
                let cells = self.cells.borrow();
                let columns = cells[row].len();
                let target = match key {
                    CellKey::Next if column + 1 < columns => Some((row, column + 1)),
                    CellKey::Next => (row + 1 < cells.len()).then_some((row + 1, 0)),
                    CellKey::Previous if column > 0 => Some((row, column - 1)),
                    CellKey::Previous => (row > 0).then(|| (row - 1, cells[row - 1].len() - 1)),
                    _ => (row + 1 < cells.len()).then(|| (row + 1, column.min(cells[row + 1].len() - 1))),
                };
                match target {
                    Some((r, c)) => {
                        let next = &cells[r][c];
                        next.view.grab_focus();
                        next.set_caret(next.text().len());
                    }
                    None => cell.view.error_bell(),
                }
            }
            CellKey::Undo => host.undo(),
            CellKey::Redo => host.redo(),
            CellKey::Reveal => host.reveal_table(self.start.get()),
        }
        true
    }

    /// Run `command` from cell (`row`, `column`).
    pub fn perform(&self, command: Command, row: usize, column: usize) {
        let Some(host) = self.host.upgrade() else { return };
        if !host.is_editable() || !host.perform_table_command(self.start.get(), command, row, column) {
            if let Some(cell) = self.cell(row, column) {
                cell.view.error_bell();
            }
        }
    }
}

fn justification(alignment: Option<&Alignment>) -> gtk4::Justification {
    match alignment {
        Some(Alignment::Center) => gtk4::Justification::Center,
        Some(Alignment::Right) => gtk4::Justification::Right,
        _ => gtk4::Justification::Left,
    }
}
