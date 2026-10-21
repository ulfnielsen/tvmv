//! The native reader/editor's controller: one `TvmvView` over a GtkTextBuffer,
//! with the Markdown source mirrored beside it. A port of the behavior in
//! `Sources/tvmv/DocumentTextView.swift`.
//!
//! - **The source is the truth.** Every buffer change is mirrored into
//!   `Model::source` by the buffer's insert and delete signals, so saving
//!   writes `source`, never the buffer. The buffer differs from the file in
//!   one way: a soft line break inside a paragraph is a space there, because
//!   a GTK paragraph cannot reflow across a newline. Both are one byte, so
//!   offsets agree; the swaps happen only here (`syncing`) and are neither
//!   mirrored nor undoable.
//! - **Parsing:** after each user action the whole source is re-parsed,
//!   synchronously up to `SYNC_PARSE_LIMIT`, otherwise on a worker thread with
//!   the latest result winning, and only the range where the layouts differ
//!   is restyled.
//! - **Undo** is this module's own (`undo.rs`), in source offsets.
//! - **Reveal:** double-click or Ctrl+' shows the markup of the span(s) under
//!   the selection until Esc or the selection leaves them; Ctrl+Alt+M shows
//!   all markup.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::ops::Range;
use std::path::PathBuf;
use std::rc::{Rc, Weak};
use std::time::{Duration, Instant};

use gtk4::prelude::*;
use gtk4::{gdk, glib, TextBuffer};

use crate::edit_rules::{self, DeleteAction};
use crate::images;
use crate::layout::{BlockImage, Heading, Style, encloses};
use crate::offsets::SourceText;

use super::styler::{Prepared, Styler};
use super::review_cards::{self, ReviewColumn};
use super::table_grid::TableGrid;
use crate::review_ops::{self, Edit as ReviewEdit};
use super::theme::NativeTheme;
use super::undo::{Change, UndoStack};
use super::view::TvmvView;

/// Documents up to this size re-parse on the main thread after each edit.
pub const SYNC_PARSE_LIMIT: usize = 64 * 1024;
/// On open, this much is styled before the first paint; the rest follows in
/// idle chunks.
const FIRST_SCREEN: usize = 32 * 1024;
const CHUNK: usize = 4 * 1024;
/// Idle time spent styling per main-loop turn while a large document opens.
const CHUNK_BUDGET: Duration = Duration::from_millis(3);
/// Styling runs after redraws (GDK_PRIORITY_REDRAW, 120) and before GTK's
/// background line validation (125): a line laid out before it is styled
/// would only be laid out again.
const STYLE_PRIORITY: i32 = 123;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ImageState {
    Loading,
    Loaded,
    Failed,
}

/// A block image by its address as written, loaded once.
pub struct Image {
    pub state: ImageState,
    pub texture: Option<gdk::Texture>,
}

/// What the view draws from, shared with `TvmvView`.
pub struct Model {
    pub source: SourceText,
    pub prepared: Rc<Prepared>,
    pub theme: NativeTheme,
    /// Reveal units whose markup is shown.
    pub revealed: Vec<Range<usize>>,
    pub show_all: bool,
    /// `prepared`, and the buffer, cover only the start of the text: a large
    /// document whose whole parse has not landed yet.
    pub partial: bool,
    pub images: HashMap<String, Image>,
    /// The text column's width, which pictures scale down to.
    pub column_width: i32,
    /// Room kept right of the text for the comment column.
    pub review_reserve: i32,
}

impl Model {
    pub fn is_revealed(&self, unit: &Range<usize>) -> bool {
        self.show_all || self.revealed.contains(unit)
    }

    /// The size a loaded block image is drawn at: its own, scaled down (never
    /// up) to the column.
    pub fn image_size(&self, image: &BlockImage) -> Option<(i32, i32)> {
        let texture = self.images.get(&image.url)?.texture.as_ref()?;
        let (w, h) = (texture.width(), texture.height());
        if w <= 0 || h <= 0 {
            return None;
        }
        let width = w.min(self.column_width.max(1));
        Some((width, (h as f64 * width as f64 / w as f64).round().max(1.0) as i32))
    }
}

pub type EditCallback = Box<dyn Fn(Range<usize>, &str)>;

/// How a table cell's view reaches its grid.
pub struct CellHooks {
    /// The cell's source `range` was replaced by `inserted`.
    pub on_edit: EditCallback,
    /// A key the grid handles; whether it did.
    pub on_key: Box<dyn Fn(CellKey) -> bool>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CellKey {
    Next,
    Previous,
    Down,
    Undo,
    Redo,
    Reveal,
    /// A table command's shortcut.
    Command(crate::table_source::Command),
}

/// A cell edit waiting for the layout it was made against.
struct CellEdit {
    start: usize,
    row: usize,
    column: usize,
    range: Range<usize>,
    inserted: String,
}

type Callback = Box<dyn Fn()>;
type LinkCallback = Box<dyn Fn(&str)>;

pub struct DocumentView {
    pub view: TvmvView,
    pub buffer: TextBuffer,
    pub model: Rc<RefCell<Model>>,
    styler: Styler,
    undo: RefCell<UndoStack>,
    me: Weak<DocumentView>,

    /// Our own buffer swaps (soft breaks, loading): not mirrored, not recorded.
    syncing: Cell<bool>,
    /// Undo and redo: mirrored, not recorded.
    replaying: Cell<bool>,
    /// From a text change until it has been parsed: caret moves the edit
    /// causes are not the user's, so they neither snap nor end a reveal.
    editing: Cell<bool>,
    snapping: Cell<bool>,
    /// An input method is composing (its text is not in the buffer yet).
    preedit: Cell<bool>,
    /// Inside the outermost user action (GTK signals only that one).
    in_user_action: Cell<bool>,
    /// Bytes at the start and end of the source unchanged since the layout was computed.
    unchanged_prefix: Cell<usize>,
    unchanged_suffix: Cell<usize>,
    generation: Cell<u64>,
    parse_in_flight: Cell<bool>,
    parse_queued: Cell<bool>,
    /// True after a reveal request, until the selection leaves every revealed unit.
    revealing: Cell<bool>,
    prev_caret: Cell<i32>,
    /// Source ranges not styled yet while a large document opens.
    untagged: RefCell<Vec<Range<usize>>>,
    tagger: RefCell<Option<glib::SourceId>>,
    /// The untagged ranges have never been styled (no edit has restyled any
    /// of them since), so styling them needs no clearing first.
    fresh_ok: Cell<bool>,
    loaded: Cell<bool>,
    last_apply: Cell<Duration>,
    /// How many parse results have been installed (diagnostics).
    applied: Cell<u64>,
    /// A link was activated (read-only click, or Ctrl+click while editing).
    on_follow_link: RefCell<Option<LinkCallback>>,
    /// The text changed (dirtiness) or a new layout was applied.
    on_changed: RefCell<Option<Callback>>,
    on_layout: RefCell<Option<Callback>>,
    /// Find: every match, and which one is current (source ranges).
    find_matches: RefCell<Vec<Range<usize>>>,
    find_current: Cell<Option<usize>>,
    find_tag: gtk4::TextTag,
    find_current_tag: gtk4::TextTag,
    /// Where `scroll_to_offset` aims; scrolling to a mark waits for layout.
    scroll_mark: gtk4::TextMark,
    /// The file, for relative image addresses and pasted images.
    document_path: RefCell<Option<PathBuf>>,
    /// What one image may cost: bytes read, pixels decoded.
    pub max_image_bytes: Cell<usize>,
    pub max_image_pixels: Cell<u64>,
    /// Spell checking (libspelling), on the source buffer. It skips text
    /// tagged no-spell-check by the styler. Replaced when anchors go in
    /// (`reset_spelling`).
    spelling: RefCell<libspelling::TextBufferAdapter>,
    /// Table grids, in source order, each on its anchor.
    grids: RefCell<Vec<(gtk4::TextChildAnchor, Rc<TableGrid>)>>,
    /// The anchor's line: half an em above and below the grid.
    table_line: gtk4::TextTag,
    /// The same, for an anchor sharing its line with hidden text (a table
    /// with no blank line above): no room below (`styler::NO_ROOM_BELOW`).
    table_line_tight: gtk4::TextTag,
    /// When this view is a table cell: how it reaches its grid.
    cell: RefCell<Option<CellHooks>>,
    /// Cell edits made while the layout was older than the text.
    pending_cell_edits: RefCell<Vec<CellEdit>>,
    /// More context-menu items (a cell's table commands).
    extra_menu: RefCell<Option<gtk4::gio::MenuModel>>,
    /// A grid row's height as last measured; placeholders use it.
    table_row_height: Cell<i32>,
    /// Building and dropping grids around the screen is queued.
    grids_pending: Cell<bool>,
    /// The comment column (not in table cells).
    review: RefCell<Option<Rc<ReviewColumn>>>,
    /// The bottom margin without room added for cards.
    base_bottom_margin: Cell<i32>,
}

/// Where the first-screen parse of a large document stops: the first blank
/// line after `FIRST_SCREEN`, so it ends between blocks.
fn preview_cut(text: &str) -> usize {
    let mut from = FIRST_SCREEN.min(text.len());
    while !text.is_char_boundary(from) {
        from += 1;
    }
    text[from..].find("\n\n").map_or(text.len(), |i| from + i + 1)
}

/// The buffer's text for `source`: soft breaks as spaces.
fn display_text(source: &str, soft_breaks: &[usize]) -> String {
    let mut bytes = source.as_bytes().to_vec();
    for &b in soft_breaks {
        if bytes.get(b) == Some(&b'\n') {
            bytes[b] = b' ';
        }
    }
    String::from_utf8(bytes).expect("a newline swapped for a space keeps UTF-8 valid")
}

fn prev_boundary(text: &str, at: usize) -> usize {
    text[..at].char_indices().next_back().map_or(0, |(i, _)| i)
}

fn next_boundary(text: &str, at: usize) -> usize {
    text[at..].chars().next().map_or(at, |c| at + c.len_utf8())
}

fn line_range(text: &str, at: usize) -> Range<usize> {
    let at = at.min(text.len());
    let bytes = text.as_bytes();
    let start = bytes[..at].iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
    let end = bytes[at..].iter().position(|&b| b == b'\n').map_or(text.len(), |i| at + i + 1);
    start..end
}

impl DocumentView {
    pub fn new(theme: NativeTheme) -> Rc<DocumentView> {
        let view = TvmvView::new();
        let buffer = view.buffer();
        buffer.set_enable_undo(false);
        // Before the styler: libspelling finds the no-spell-check tag when it
        // is added to the tag table, not one that is already there. It then
        // re-checks a range whenever that tag is applied or removed.
        libspelling::init();
        let source_buffer = buffer.clone().downcast::<sourceview5::Buffer>().expect("a GtkSourceView buffer");
        let spelling = libspelling::TextBufferAdapter::new(&source_buffer, &libspelling::Checker::default());
        spelling.set_enabled(true);
        view.insert_action_group("spelling", Some(&spelling));
        let styler = Styler::new(&buffer, &theme);
        let theme_em = theme.em();
        // Added after the styler's tags, so a match shows over any style.
        let find_tag = gtk4::TextTag::new(Some("find"));
        let find_current_tag = gtk4::TextTag::new(Some("find-current"));
        buffer.tag_table().add(&find_tag);
        buffer.tag_table().add(&find_current_tag);
        let scroll_mark = buffer.create_mark(None, &buffer.start_iter(), true);
        let table_line = gtk4::TextTag::new(None);
        buffer.tag_table().add(&table_line);
        let table_line_tight = gtk4::TextTag::new(None);
        buffer.tag_table().add(&table_line_tight);
        let model = Rc::new(RefCell::new(Model {
            source: SourceText::new(String::new()),
            prepared: Rc::new(Prepared::default()),
            theme,
            revealed: Vec::new(),
            show_all: false,
            partial: false,
            images: HashMap::new(),
            column_width: 0,
            review_reserve: 0,
        }));
        view.set_model(Rc::clone(&model));
        let doc = Rc::new_cyclic(|me| DocumentView {
            view,
            buffer,
            model,
            styler,
            undo: RefCell::new(UndoStack::default()),
            me: me.clone(),
            syncing: Cell::new(false),
            replaying: Cell::new(false),
            editing: Cell::new(false),
            snapping: Cell::new(false),
            preedit: Cell::new(false),
            in_user_action: Cell::new(false),
            unchanged_prefix: Cell::new(usize::MAX),
            unchanged_suffix: Cell::new(usize::MAX),
            generation: Cell::new(0),
            parse_in_flight: Cell::new(false),
            parse_queued: Cell::new(false),
            revealing: Cell::new(false),
            prev_caret: Cell::new(0),
            untagged: RefCell::new(Vec::new()),
            tagger: RefCell::new(None),
            fresh_ok: Cell::new(false),
            loaded: Cell::new(false),
            last_apply: Cell::new(Duration::ZERO),
            applied: Cell::new(0),
            on_follow_link: RefCell::new(None),
            on_changed: RefCell::new(None),
            on_layout: RefCell::new(None),
            find_matches: RefCell::new(Vec::new()),
            find_current: Cell::new(None),
            find_tag,
            find_current_tag,
            scroll_mark,
            document_path: RefCell::new(None),
            max_image_bytes: Cell::new(images::MAX_BYTES),
            max_image_pixels: Cell::new(images::MAX_PIXELS),
            spelling: RefCell::new(spelling),
            grids: RefCell::default(),
            table_line,
            table_line_tight,
            cell: RefCell::new(None),
            pending_cell_edits: RefCell::default(),
            extra_menu: RefCell::new(None),
            table_row_height: Cell::new((theme_em * 2.45).round() as i32),
            grids_pending: Cell::new(false),
            review: RefCell::new(None),
            base_bottom_margin: Cell::new(0),
        });
        doc.base_bottom_margin.set(doc.view.bottom_margin());
        doc.add_review_actions();
        doc.shape_table_line();
        doc.color_find_tags();
        doc.apply_css();
        doc.set_editable(false);
        doc.connect();
        doc
    }

    pub fn set_on_follow_link(&self, f: impl Fn(&str) + 'static) {
        *self.on_follow_link.borrow_mut() = Some(Box::new(f));
    }

    pub fn set_on_changed(&self, f: impl Fn() + 'static) {
        *self.on_changed.borrow_mut() = Some(Box::new(f));
    }

    pub fn set_on_layout(&self, f: impl Fn() + 'static) {
        *self.on_layout.borrow_mut() = Some(Box::new(f));
    }

    /// The document as it would be saved.
    pub fn text(&self) -> String {
        self.model.borrow().source.text().to_string()
    }

    pub fn is_editable(&self) -> bool {
        self.view.is_editable()
    }

    pub fn set_editable(&self, editable: bool) {
        self.view.set_editable(editable);
        self.update_cursor();
        self.update_spelling_menu();
        for (_, grid) in self.grids.borrow().iter() {
            grid.set_editable(editable);
        }
    }

    /// The caret shows while editing, in the view with the focus only. GTK
    /// draws it in an unfocused view too: with a table cell or a reply field
    /// focused, the document's caret would stay on show beside it.
    fn update_cursor(&self) {
        self.view.set_cursor_visible(self.view.is_editable() && self.view.has_focus());
    }

    /// Turn spell checking on or off (Settings → Check spelling).
    pub fn set_spelling(&self, on: bool) {
        let spelling = self.spelling();
        if spelling.is_enabled() != on {
            spelling.set_enabled(on);
        }
        self.update_spelling_menu();
    }

    /// Misspellings show while reading too, as on macOS; the corrections
    /// change the text, so they are offered only while editing.
    fn update_spelling_menu(&self) {
        let editable = self.view.is_editable();
        let menu = gtk4::gio::Menu::new();
        let spelling = self.spelling();
        if editable && spelling.is_enabled() {
            menu.append_section(None, &spelling.menu_model());
        }
        if let Some(extra) = self.extra_menu.borrow().as_ref().filter(|_| editable) {
            menu.append_section(None, extra);
        }
        // Commenting doesn't need edit mode.
        if self.cell.borrow().is_none() {
            let review = gtk4::gio::Menu::new();
            review.append(Some("Comment…"), Some("review.comment"));
            review.append(Some("Suggest Edit…"), Some("review.suggest"));
            menu.append_section(None, &review);
        }
        self.view.set_extra_menu((menu.n_items() > 0).then_some(menu).as_ref());
    }

    /// More context-menu items, shown while editing.
    pub fn set_extra_menu(&self, menu: Option<gtk4::gio::MenuModel>) {
        *self.extra_menu.borrow_mut() = menu;
        self.update_spelling_menu();
    }

    pub fn is_loaded(&self) -> bool {
        self.loaded.get()
    }

    pub fn show_all_markup(&self) -> bool {
        self.model.borrow().show_all
    }

    /// The theme's stylesheet. One provider serves every view (a table's
    /// cells are views too): providers are display-wide, and settings are
    /// global, so all views share one theme.
    fn apply_css(&self) {
        thread_local! {
            static CSS: (gtk4::CssProvider, RefCell<String>) = {
                let provider = gtk4::CssProvider::new();
                if let Some(display) = gdk::Display::default() {
                    gtk4::style_context_add_provider_for_display(
                        &display,
                        &provider,
                        gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
                    );
                }
                (provider, RefCell::new(String::new()))
            };
        }
        let css = self.model.borrow().theme.css();
        CSS.with(|(provider, loaded)| {
            if *loaded.borrow() != css {
                provider.load_from_string(&css);
                *loaded.borrow_mut() = css;
            }
        });
    }

    pub fn set_theme(&self, theme: NativeTheme) {
        if self.model.borrow().theme == theme {
            return;
        }
        self.styler.set_theme(&theme);
        self.model.borrow_mut().theme = theme;
        self.color_find_tags();
        self.shape_table_line();
        self.apply_css();
        self.view.queue_resize();
        self.restyle_all();
    }

    // MARK: Content

    /// Replace the whole text (initial load, external reload). Not undoable.
    pub fn load(&self, text: String) {
        self.generation.set(self.generation.get() + 1);
        self.undo.borrow_mut().clear();
        self.unchanged_prefix.set(usize::MAX);
        self.unchanged_suffix.set(usize::MAX);
        self.revealing.set(false);
        if let Some(id) = self.tagger.borrow_mut().take() {
            id.remove();
        }
        let small = text.len() <= SYNC_PARSE_LIMIT;
        // Large: the first screen is parsed on its own, now, and styled
        // from that while the whole text parses off the main thread.
        let cut = if small { text.len() } else { preview_cut(&text) };
        let prepared = Prepared::parse(&text[..cut]);
        let display = display_text(&text, &prepared.layout.soft_breaks);
        {
            let mut model = self.model.borrow_mut();
            model.source = SourceText::new(text.clone());
            model.prepared = Rc::new(prepared);
            model.partial = !small;
            model.revealed.clear();
        }
        // A large document's buffer holds only the first screen until its
        // whole parse lands: filling a GtkTextBuffer costs ~17 ms per MB.
        self.set_buffer_text(&display[..cut]);
        self.style(0..cut, true);
        if small {
            self.loaded.set(true);
            self.notify_layout();
            return;
        }
        // Until the whole parse lands, nothing is editable.
        self.loaded.set(false);
        let generation = self.generation.get();
        let me = self.me.clone();
        self.parse_off_thread(text, move |prepared| {
            let Some(doc) = me.upgrade() else { return };
            if doc.generation.get() != generation {
                return;
            }
            let display = display_text(doc.model.borrow().source.text(), &prepared.layout.soft_breaks);
            let len = prepared.layout.length;
            {
                let mut model = doc.model.borrow_mut();
                model.prepared = Rc::new(prepared);
                model.partial = false;
            }
            doc.set_buffer_text(&display);
            doc.loaded.set(true);
            doc.style(0..FIRST_SCREEN.min(len), true);
            doc.style_lazily(std::iter::once(FIRST_SCREEN.min(len)..len).collect(), true);
            doc.notify_layout();
        });
    }

    fn set_buffer_text(&self, display: &str) {
        // Replacing the text removes every anchor, and its grid with it.
        self.grids.borrow_mut().clear();
        self.syncing.set(true);
        self.buffer.set_text(display);
        self.buffer.place_cursor(&self.buffer.start_iter());
        self.syncing.set(false);
        self.prev_caret.set(0);
    }

    fn parse_off_thread(&self, text: String, done: impl FnOnce(Prepared) + 'static) {
        let (sender, receiver) = async_channel::bounded(1);
        std::thread::spawn(move || {
            let _ = sender.send_blocking(Prepared::parse(&text));
        });
        glib::spawn_future_local(async move {
            if let Ok(prepared) = receiver.recv().await {
                done(prepared);
            }
        });
    }

    /// Style `ranges` a chunk at a time while the main loop is idle; `fresh`
    /// when they have never been styled.
    fn style_lazily(&self, ranges: Vec<Range<usize>>, fresh: bool) {
        if let Some(id) = self.tagger.borrow_mut().take() {
            id.remove();
        }
        self.fresh_ok.set(fresh);
        *self.untagged.borrow_mut() = ranges.into_iter().filter(|r| !r.is_empty()).collect();
        let me = self.me.clone();
        let id = glib::idle_add_local_full(glib::Priority::from(STYLE_PRIORITY), move || {
            let Some(doc) = me.upgrade() else { return glib::ControlFlow::Break };
            let start = Instant::now();
            while start.elapsed() < CHUNK_BUDGET {
                let next = {
                    let mut untagged = doc.untagged.borrow_mut();
                    let Some(first) = untagged.first_mut() else { break };
                    let chunk = first.start..(first.start + CHUNK).min(first.end);
                    first.start = chunk.end;
                    if first.start >= first.end {
                        untagged.remove(0);
                    }
                    chunk
                };
                // Only what a later edit has not restyled meanwhile is fresh;
                // an edit inside it merged it into this range.
                doc.style(next, doc.fresh_ok.get());
            }
            if doc.untagged.borrow().is_empty() {
                doc.tagger.borrow_mut().take();
                glib::ControlFlow::Break
            } else {
                glib::ControlFlow::Continue
            }
        });
        *self.tagger.borrow_mut() = Some(id);
    }

    /// Stop styling in the background (diagnostics).
    pub fn stop_styling(&self) {
        if let Some(id) = self.tagger.borrow_mut().take() {
            id.remove();
        }
        self.untagged.borrow_mut().clear();
    }

    /// Unstyled ranges move with an edit of old range `edit` by `delta`.
    fn shift_untagged(&self, edit: &Range<usize>, delta: isize) {
        for r in self.untagged.borrow_mut().iter_mut() {
            let shift = |o: usize| o.saturating_add_signed(delta);
            if r.start >= edit.end {
                *r = shift(r.start)..shift(r.end);
            } else if r.end > edit.start {
                *r = r.start.min(edit.start)..shift(r.end.max(edit.end));
            }
        }
    }

    // MARK: The edit path

    /// Replace source `range` with `text`, undoably, exactly as asked: the
    /// keystroke rules around hidden markup do not apply.
    pub fn replace(&self, range: Range<usize>, text: &str) {
        let (b0, b1) = {
            let model = self.model.borrow();
            let len = model.source.text().len();
            (model.source.to_buffer(range.start.min(len)), model.source.to_buffer(range.end.min(len)))
        };
        self.buffer.begin_user_action();
        if b1 > b0 {
            self.buffer.delete(&mut self.buffer.iter_at_offset(b0), &mut self.buffer.iter_at_offset(b1));
        }
        if !text.is_empty() {
            self.buffer.insert(&mut self.buffer.iter_at_offset(b0), text);
        }
        self.buffer.end_user_action();
    }

    /// Put the caret at source offset `at`.
    pub fn set_caret(&self, at: usize) {
        let offset = self.model.borrow().source.to_buffer(at);
        self.buffer.place_cursor(&self.buffer.iter_at_offset(offset));
    }

    /// Select source range `range`.
    pub fn select(&self, range: Range<usize>) {
        let (a, b) = {
            let model = self.model.borrow();
            (model.source.to_buffer(range.start), model.source.to_buffer(range.end))
        };
        self.buffer.select_range(&self.buffer.iter_at_offset(b), &self.buffer.iter_at_offset(a));
    }

    /// The selection in source offsets.
    pub fn selection(&self) -> Range<usize> {
        let model = self.model.borrow();
        match self.buffer.selection_bounds() {
            Some((a, b)) => model.source.to_source(a.offset())..model.source.to_source(b.offset()),
            None => {
                let c = model.source.to_source(self.buffer.cursor_position());
                c..c
            }
        }
    }

    fn caret_source(&self) -> usize {
        self.model.borrow().source.to_source(self.buffer.cursor_position())
    }

    pub fn can_undo(&self) -> bool {
        self.undo.borrow().can_undo()
    }

    pub fn undo(&self) {
        let Some(step) = self.undo.borrow_mut().undo() else { return };
        self.replay(step.changes.iter().rev().map(Change::inverse).collect(), step.caret_before);
    }

    pub fn redo(&self) {
        let Some(step) = self.undo.borrow_mut().redo() else { return };
        self.replay(step.changes, step.caret_after);
    }

    fn replay(&self, changes: Vec<Change>, caret: usize) {
        self.replaying.set(true);
        self.buffer.begin_user_action();
        for change in changes {
            self.replace(change.range, &change.inserted);
        }
        self.buffer.end_user_action();
        self.replaying.set(false);
        self.set_caret(caret);
    }

    // MARK: Signals

    fn connect(&self) {
        let me = self.me.clone();
        self.view.connect_has_focus_notify(move |_| {
            if let Some(doc) = me.upgrade() {
                doc.update_cursor();
            }
        });
        // An image on the clipboard with no text pastes as a picture.
        let me = self.me.clone();
        self.view.connect_paste_clipboard(move |view| {
            let Some(doc) = me.upgrade() else { return };
            let formats = view.clipboard().formats();
            let text = formats.contain_mime_type("text/plain") || formats.contain_mime_type("text/plain;charset=utf-8");
            if text || !formats.contains_type(gdk::Texture::static_type()) || !doc.is_editable() {
                return;
            }
            view.stop_signal_emission_by_name("paste-clipboard");
            let me = doc.me.clone();
            view.clipboard().read_texture_async(gtk4::gio::Cancellable::NONE, move |result| {
                if let (Some(doc), Ok(Some(texture))) = (me.upgrade(), result) {
                    doc.paste_image(&texture);
                }
            });
        });
        let me = self.me.clone();
        self.buffer.connect_insert_text(move |_, iter, text| {
            if let Some(doc) = me.upgrade() {
                doc.mirror_insert(iter.offset(), text);
            }
        });
        let me = self.me.clone();
        self.buffer.connect_delete_range(move |_, start, end| {
            if let Some(doc) = me.upgrade() {
                doc.mirror_delete(start.offset()..end.offset());
            }
        });
        let me = self.me.clone();
        self.buffer.connect_begin_user_action(move |_| {
            if let Some(doc) = me.upgrade() {
                doc.in_user_action.set(true);
                doc.undo.borrow_mut().begin_group();
            }
        });
        let me = self.me.clone();
        self.buffer.connect_end_user_action(move |_| {
            if let Some(doc) = me.upgrade() {
                doc.in_user_action.set(false);
                doc.undo.borrow_mut().end_group();
                if doc.editing.get() {
                    doc.text_changed();
                }
            }
        });
        let me = self.me.clone();
        self.buffer.connect_mark_set(move |buffer, iter, mark| {
            let Some(doc) = me.upgrade() else { return };
            if mark == &buffer.get_insert() {
                doc.caret_moved(iter.offset());
            }
        });
        let me = self.me.clone();
        self.view.connect_preedit_changed(move |_, preedit| {
            if let Some(doc) = me.upgrade() {
                doc.preedit.set(!preedit.is_empty());
            }
        });
        let me = self.me.clone();
        self.view.connect_backspace(move |view| {
            if let Some(doc) = me.upgrade() {
                if doc.retarget(false) {
                    view.stop_signal_emission_by_name("backspace");
                }
            }
        });
        let me = self.me.clone();
        self.view.connect_delete_from_cursor(move |view, kind, count| {
            let Some(doc) = me.upgrade() else { return };
            if kind == gtk4::DeleteType::Chars && count == 1 && doc.retarget(true) {
                view.stop_signal_emission_by_name("delete-from-cursor");
            }
        });
        let me = self.me.clone();
        self.view.connect_copy_clipboard(move |view| {
            if let Some(doc) = me.upgrade() {
                doc.copy();
                view.stop_signal_emission_by_name("copy-clipboard");
            }
        });
        let me = self.me.clone();
        self.view.connect_cut_clipboard(move |view| {
            if let Some(doc) = me.upgrade() {
                doc.cut();
                view.stop_signal_emission_by_name("cut-clipboard");
            }
        });
        let view = self.view.clone();
        let me = self.me.clone();
        let me_drawn = self.me.clone();
        self.view.set_on_drawn(move |visible| {
            if let Some(doc) = me_drawn.upgrade() {
                doc.grids_on_screen(visible);
                // Lines above the cards are laid out as GTK gets to them.
                if let Some(column) = doc.review.borrow().as_ref() {
                    column.queue_layout();
                }
            }
        });
        self.view.set_on_column(move |x, width| {
            if let Some(doc) = me.upgrade() {
                doc.styler.set_column_x(x);
                doc.column_changed(width);
            }
            view.queue_draw();
        });
        self.connect_keys();
        self.connect_pointer();
    }

    fn mirror_insert(&self, offset: i32, text: &str) {
        if self.syncing.get() {
            return;
        }
        let caret = self.buffer.cursor_position();
        let (at, old_len) = {
            let mut model = self.model.borrow_mut();
            let old_len = model.source.text().len();
            (model.source.insert(offset, text), old_len)
        };
        self.note_edit(at..at, old_len);
        let is_cell = self.cell.borrow().is_some();
        if !self.replaying.get() && !is_cell {
            let caret_before = self.model.borrow().source.to_source(caret.min(offset));
            let change = Change { range: at..at, removed: String::new(), inserted: text.to_string() };
            self.undo.borrow_mut().record(change, caret_before.min(at), at + text.len());
        }
        if let Some(hooks) = self.cell.borrow().as_ref() {
            (hooks.on_edit)(at..at, text);
        }
        self.edited();
    }

    fn mirror_delete(&self, range: Range<i32>) {
        if self.syncing.get() || range.is_empty() {
            return;
        }
        let caret = self.buffer.cursor_position();
        let (source_range, removed, old_len) = {
            let mut model = self.model.borrow_mut();
            let old_len = model.source.text().len();
            let source_range = model.source.to_source(range.start)..model.source.to_source(range.end);
            let removed = model.source.text()[source_range.clone()].to_string();
            model.source.delete(range.clone());
            (source_range, removed, old_len)
        };
        self.note_edit(source_range.clone(), old_len);
        let is_cell = self.cell.borrow().is_some();
        if let Some(hooks) = self.cell.borrow().as_ref() {
            (hooks.on_edit)(source_range.clone(), "");
        }
        if !self.replaying.get() && !is_cell {
            let caret_before = if caret >= range.end { source_range.end } else { source_range.start };
            let start = source_range.start;
            self.undo.borrow_mut().record(Change { range: source_range, removed, inserted: String::new() }, caret_before, start);
        }
        self.edited();
    }

    /// Track the extent of the edits since the layout was computed.
    fn note_edit(&self, old_range: Range<usize>, old_len: usize) {
        self.unchanged_prefix.set(self.unchanged_prefix.get().min(old_range.start));
        self.unchanged_suffix.set(self.unchanged_suffix.get().min(old_len - old_range.end));
    }

    fn edited(&self) {
        self.editing.set(true);
        // Outside a user action (a programmatic edit by GTK itself), parse now.
        if !self.in_user_action.get() {
            self.text_changed();
        }
    }

    // MARK: Parse + restyle

    /// Re-parse after edits.
    fn text_changed(&self) {
        self.editing.set(false);
        if let Some(f) = self.on_changed.borrow().as_ref() {
            f();
        }
        if self.preedit.get() || !self.loaded.get() {
            return;
        }
        let (text, old) = {
            let model = self.model.borrow();
            (model.source.text().to_string(), Rc::clone(&model.prepared))
        };
        let old_len = old.layout.length;
        let prefix = self.unchanged_prefix.get().min(old_len);
        let suffix = self.unchanged_suffix.get().min(old_len - prefix);
        let edit = prefix..old_len - suffix;
        let delta = text.len() as isize - old_len as isize;
        self.generation.set(self.generation.get() + 1);
        let generation = self.generation.get();
        if text.len() <= SYNC_PARSE_LIMIT {
            let prepared = Prepared::parse(&text);
            self.apply_parsed(prepared, &old, edit, delta, generation);
            return;
        }
        if self.parse_in_flight.get() {
            self.parse_queued.set(true);
            return;
        }
        self.parse_in_flight.set(true);
        let me = self.me.clone();
        self.parse_off_thread(text, move |prepared| {
            let Some(doc) = me.upgrade() else { return };
            doc.parse_in_flight.set(false);
            doc.apply_parsed(prepared, &old, edit, delta, generation);
            if doc.parse_queued.replace(false) {
                doc.text_changed();
            }
        });
    }

    /// Install a parse result unless a newer edit has superseded it (latest wins).
    fn apply_parsed(&self, new: Prepared, old: &Prepared, edit: Range<usize>, delta: isize, generation: u64) {
        if generation != self.generation.get()
            || self.preedit.get()
            || new.layout.length != self.model.borrow().source.text().len()
        {
            return;
        }
        let started = Instant::now();
        self.unchanged_prefix.set(usize::MAX);
        self.unchanged_suffix.set(usize::MAX);
        let changed = new.layout.changed_range(&old.layout, edit.clone(), delta);
        self.shift_untagged(&edit, delta);
        self.fresh_ok.set(false);
        self.model.borrow_mut().prepared = Rc::new(new);
        self.update_revealed_units();
        self.sync_soft_breaks(changed.clone());
        self.restyle(changed);
        self.last_apply.set(started.elapsed());
        self.applied.set(self.applied.get() + 1);
        self.notify_layout();
    }

    fn notify_layout(&self) {
        self.flush_cell_edits();
        self.sync_tables();
        self.update_review();
        self.request_images();
        self.view.queue_draw();
        if let Some(f) = self.on_layout.borrow().as_ref() {
            f();
        }
    }

    /// Make the buffer show each newline in `range` as the layout wants it: a
    /// space for a soft break, a newline otherwise.
    fn sync_soft_breaks(&self, range: Range<usize>) {
        let swaps: Vec<(i32, char)> = {
            let model = self.model.borrow();
            let text = model.source.text();
            let breaks = &model.prepared.layout.soft_breaks;
            let range = line_range(text, range.start).start..line_range(text, range.end).end;
            text.as_bytes()[range.clone()]
                .iter()
                .enumerate()
                .filter(|&(_, &b)| b == b'\n')
                .filter_map(|(i, _)| {
                    let at = range.start + i;
                    let want = if breaks.binary_search(&at).is_ok() { ' ' } else { '\n' };
                    let offset = model.source.to_buffer(at);
                    (self.buffer.iter_at_offset(offset).char() != want).then_some((offset, want))
                })
                .collect()
        };
        if swaps.is_empty() {
            return;
        }
        let selection = self.buffer.selection_bounds().map(|(a, b)| (a.offset(), b.offset()));
        let caret = self.buffer.cursor_position();
        self.syncing.set(true);
        for (offset, want) in swaps {
            let mut start = self.buffer.iter_at_offset(offset);
            let mut end = self.buffer.iter_at_offset(offset + 1);
            self.buffer.delete(&mut start, &mut end);
            self.buffer.insert(&mut self.buffer.iter_at_offset(offset), &want.to_string());
        }
        match selection {
            Some((a, b)) => self.buffer.select_range(&self.buffer.iter_at_offset(b), &self.buffer.iter_at_offset(a)),
            None => self.buffer.place_cursor(&self.buffer.iter_at_offset(caret)),
        }
        self.syncing.set(false);
    }

    /// Restyle source `range`, widened to whole lines.
    pub fn restyle(&self, range: Range<usize>) {
        self.style(range, false);
    }

    /// Style source `range`, widened to whole lines; `fresh` when it has
    /// never been styled.
    fn style(&self, range: Range<usize>, fresh: bool) {
        let model = self.model.borrow();
        let text = model.source.text();
        let range = line_range(text, range.start).start..line_range(text, range.end).end;
        let revealed = |unit: &Range<usize>| model.is_revealed(unit);
        let view = &self.view;
        let width = |s: &str| view.text_width(s);
        let image_height = |image: &BlockImage| model.image_size(image).map(|(_, h)| h);
        self.styler.apply(
            &model.source,
            &model.prepared,
            range.clone(),
            fresh,
            &model.theme,
            &revealed,
            &width,
            &image_height,
        );
        // Restyling clears the anchors' line tag where it starts before them.
        let anchors = model.source.anchors();
        let from = anchors.partition_point(|&a| a < range.start);
        for &at in anchors[from..].iter().take_while(|&&a| a <= range.end) {
            let after = model.source.to_buffer(at);
            let tag = self.anchor_line_tag(model.source.text(), at);
            self.buffer.apply_tag(tag, &self.buffer.iter_at_offset(after - 1), &self.buffer.iter_at_offset(after));
        }
        // Styling clears every tag in the range, find's too.
        self.tag_matches(&model, range);
        self.view.queue_draw();
    }

    // MARK: Review

    fn add_review_actions(&self) {
        let group = gtk4::gio::SimpleActionGroup::new();
        for (name, suggestion) in [("comment", false), ("suggest", true)] {
            let action = gtk4::gio::SimpleAction::new(name, None);
            let me = self.me.clone();
            action.connect_activate(move |_, _| {
                if let Some(doc) = me.upgrade() {
                    doc.open_composer(suggestion);
                }
            });
            group.add_action(&action);
        }
        self.view.insert_action_group("review", Some(&group));
    }

    /// The comment column, created on first use.
    fn review_column(&self) -> Rc<ReviewColumn> {
        if let Some(c) = self.review.borrow().as_ref() {
            return Rc::clone(c);
        }
        let column = ReviewColumn::new(&self.me.upgrade().expect("a live view"));
        *self.review.borrow_mut() = Some(Rc::clone(&column));
        // The cards are in the gutter, which doesn't scroll: they follow.
        let follow = |view: &TvmvView, column: &Rc<ReviewColumn>| {
            if let Some(adj) = view.vadjustment() {
                let column = Rc::downgrade(column);
                adj.connect_value_changed(move |_| {
                    if let Some(column) = column.upgrade() {
                        column.scrolled();
                    }
                });
            }
        };
        follow(&self.view, &column);
        let weak = Rc::downgrade(&column);
        self.view.connect_vadjustment_notify(move |view| {
            if let Some(column) = weak.upgrade() {
                follow(view, &column);
            }
        });
        column
    }

    /// The column (diagnostics and tests).
    pub fn review_cards(&self) -> Option<Rc<ReviewColumn>> {
        self.review.borrow().clone()
    }

    /// Cards for the threads of the current layout.
    fn update_review(&self) {
        if self.cell.borrow().is_some() {
            return;
        }
        let models = {
            let model = self.model.borrow();
            match model.prepared.layout.review.as_ref() {
                Some(review) if model.prepared.layout.length == model.source.text().len() => {
                    review_ops::cards(review, model.source.text())
                }
                Some(_) => return,
                None => Vec::new(),
            }
        };
        if models.is_empty() && self.review.borrow().is_none() {
            return;
        }
        self.review_column().update(models);
        self.review_column_changed();
        self.update_review_focus();
    }

    /// The column appeared or went: the text column makes room, or takes it back.
    pub fn review_column_changed(&self) {
        let shows = self.review.borrow().as_ref().is_some_and(|c| c.shows());
        let reserve = if shows { review_cards::COLUMN_WIDTH } else { 0 };
        if self.model.borrow().review_reserve != reserve {
            self.model.borrow_mut().review_reserve = reserve;
            self.view.queue_resize();
        }
    }

    /// The top of the line holding source offset `at`, in buffer coordinates.
    pub fn line_top(&self, at: usize) -> i32 {
        let model = self.model.borrow();
        let at = at.min(model.source.text().len());
        self.view.location(&self.buffer.iter_at_offset(model.source.to_buffer(at))).y()
    }

    /// Make room below the text for cards reaching down to `bottom`.
    pub fn reserve_bottom(&self, bottom: i32) {
        let base = self.base_bottom_margin.get();
        let end = self.buffer.end_iter();
        let (y, h) = self.view.line_yrange(&end);
        let text_bottom = y + h;
        let wanted = if bottom + 24 > text_bottom { base + bottom + 24 - text_bottom } else { base };
        if self.view.bottom_margin() != wanted {
            self.view.set_bottom_margin(wanted);
        }
    }

    /// Focus the card of the anchor the caret is in (none outside anchors).
    fn update_review_focus(&self) {
        let Some(column) = self.review.borrow().clone() else { return };
        let id = {
            let model = self.model.borrow();
            let caret = model.source.to_source(self.buffer.cursor_position());
            model.prepared.layout.review.as_ref().and_then(|r| {
                r.anchors
                    .iter()
                    .find(|a| a.range.contains(&caret) || (caret > 0 && a.range.contains(&(caret - 1))))
                    .map(|a| a.id.clone())
            })
        };
        column.focus(id.as_deref(), false);
    }

    /// Apply review `edits` as one undoable step, read-only or not.
    pub fn apply_review(&self, edits: &[ReviewEdit]) -> bool {
        if edits.is_empty() {
            return false;
        }
        let caret = self.selection().start;
        self.buffer.begin_user_action();
        for e in edits.iter().rev() {
            self.replace(e.range.clone(), &e.insert);
        }
        self.buffer.end_user_action();
        self.set_caret(review_ops::caret_through(caret, edits));
        true
    }

    fn author(&self) -> String {
        let folder = self.document_path.borrow().as_ref().and_then(|p| p.parent().map(PathBuf::from));
        review_ops::current_author(folder.as_deref())
    }

    fn today() -> String {
        glib::DateTime::now_local().and_then(|t| t.format("%Y-%m-%d")).map_or_else(|_| "1970-01-01".into(), |s| s.to_string())
    }

    /// Comment on the selection (a point comment at a caret). The new
    /// thread's id, or `None` when the selection can't hold one.
    pub fn add_comment(&self, body: &str, author: &str, date: &str) -> Option<String> {
        let text = self.text();
        let ops = review_ops::Ops::new(&text);
        let id = review_ops::new_id(&ops.ids());
        let edits = ops.add_comment(self.selection(), body, &review_ops::Byline { author, date }, Some(&id));
        self.apply_review(&edits).then_some(id)
    }

    /// Suggest `replacement` for the selection.
    pub fn add_suggestion(&self, replacement: &str, body: &str, author: &str, date: &str) -> Option<String> {
        let text = self.text();
        let ops = review_ops::Ops::new(&text);
        let id = review_ops::new_id(&ops.ids());
        let edits =
            ops.add_suggestion(self.selection(), replacement, body, &review_ops::Byline { author, date }, Some(&id));
        self.apply_review(&edits).then_some(id)
    }

    pub fn reply(&self, id: &str, body: &str, author: &str, date: &str) -> bool {
        let text = self.text();
        self.apply_review(&review_ops::Ops::new(&text).reply(id, body, &review_ops::Byline { author, date }))
    }

    /// Settle thread `id`: resolve it, or accept or reject its suggestion.
    pub fn settle(&self, id: &str, action: &review_cards::Action) -> bool {
        let text = self.text();
        let ops = review_ops::Ops::new(&text);
        let edits = match action {
            review_cards::Action::Accept => ops.accept(id),
            review_cards::Action::Reject | review_cards::Action::RemoveMarkup => ops.reject(id),
            _ => ops.resolve(id),
        };
        self.apply_review(&edits)
    }

    pub fn settle_all(&self, accepting: bool) -> bool {
        let text = self.text();
        let ops = review_ops::Ops::new(&text);
        let edits = if accepting { ops.accept_all() } else { ops.reject_all() };
        let ok = self.apply_review(&edits);
        if !ok {
            self.view.error_bell();
        }
        ok
    }

    /// What a card's button or reply asks for.
    pub fn card_action(&self, id: &str, action: review_cards::Action) {
        let done = match &action {
            review_cards::Action::Reply(body) => self.reply(id, body, &self.author(), &Self::today()),
            other => self.settle(id, other),
        };
        if !done {
            self.view.error_bell();
        }
    }

    /// Write a comment (or a suggestion) on the selection in a card in the
    /// comment column.
    pub fn open_composer(&self, suggestion: bool) -> bool {
        if self.cell.borrow().is_some() || !self.is_loaded() {
            // A cell's selection is in its own text: not supported yet.
            self.view.error_bell();
            return true;
        }
        let selection = self.selection();
        let original = self.text();
        let selected = suggestion.then(|| original[selection.clone()].to_string());
        let anchor = selection.start;
        let me = self.me.clone();
        let submit: review_cards::Submit = Box::new(move |body, replacement| {
            let Some(doc) = me.upgrade() else { return Ok(()) };
            // The selection is an offset into the text as it was: if the text
            // changed meanwhile, it would land on other words.
            if doc.text() != original {
                return Err("The document changed. Cancel and select the text again.".into());
            }
            doc.select(selection.clone());
            let (author, date) = (doc.author(), Self::today());
            let added = match replacement {
                Some(r) => doc.add_suggestion(r, body, &author, &date),
                None => doc.add_comment(body, &author, &date),
            };
            added.map(|_| ()).ok_or_else(|| "Select text within one paragraph, outside code and other comments.".into())
        });
        self.review_column().open_composer(selected.as_deref(), anchor, submit);
        true
    }

    /// Put the caret at the next (previous) thread's anchor, wrapping round.
    pub fn move_to_thread(&self, forward: bool) -> bool {
        let text = self.text();
        let anchors: Vec<usize> = review_ops::cards(&crate::review::parse(&text), &text)
            .into_iter()
            .filter(|c| c.kind != review_ops::CardKind::OrphanThread)
            .map(|c| c.anchor)
            .collect();
        if anchors.is_empty() {
            self.view.error_bell();
            return true;
        }
        let caret = self.selection().start;
        let target = if forward {
            anchors.iter().copied().find(|&a| a > caret).unwrap_or(anchors[0])
        } else {
            anchors.iter().copied().rev().find(|&a| a < caret).unwrap_or(anchors[anchors.len() - 1])
        };
        self.set_caret(target);
        self.view.scroll_to_mark(&self.buffer.get_insert(), 0.1, false, 0.0, 0.0);
        true
    }

    // MARK: Tables

    /// The anchor's line: the anchor sits on the blank line above its table
    /// (`table_source::anchor_offset`), taking the gap that line made, so it
    /// keeps that gap above as well as half an em each side. That line holds
    /// no hidden text, so room below is safe; on a table's own first line it
    /// is not (`styler::NO_ROOM_BELOW`).
    fn shape_table_line(&self) {
        let em = self.model.borrow().theme.em();
        self.table_line.set_pixels_above_lines((em * 1.5).round() as i32);
        self.table_line.set_pixels_below_lines((em / 2.0).round() as i32);
        self.table_line_tight.set_pixels_above_lines(em.round() as i32);
        self.table_line_tight.set_pixels_below_lines(0);
    }

    /// The line tag for an anchor before source offset `at`.
    fn anchor_line_tag(&self, text: &str, at: usize) -> &gtk4::TextTag {
        if text.as_bytes().get(at) == Some(&b'\n') { &self.table_line } else { &self.table_line_tight }
    }

    /// The spell checker's adapter on this buffer.
    pub fn spelling(&self) -> libspelling::TextBufferAdapter {
        self.spelling.borrow().clone()
    }

    /// A fresh spelling adapter, after child anchors went in. libspelling
    /// follows the buffer's length through its inserts and deletes, and an
    /// anchor is neither (on GTK 4.22 it fires no commit notify, and
    /// libspelling 0.2 heard only insert-text and delete-range): the adapter
    /// ends up an anchor short, and a later delete over the end fails its
    /// assertion and aborts. A new adapter reads the length afresh. It adopts
    /// the no-spell-check tag only when that is added to the tag table, so
    /// the tag goes out and back in, and is applied again.
    fn reset_spelling(&self) {
        let Ok(source_buffer) = self.buffer.clone().downcast::<sourceview5::Buffer>() else { return };
        let old = self.spelling();
        let enabled = old.is_enabled();
        let checker = old.checker().unwrap_or_else(libspelling::Checker::default);
        old.set_enabled(false);
        let old_tag = old.tag();
        let fresh = libspelling::TextBufferAdapter::new(&source_buffer, &checker);
        fresh.set_enabled(enabled);
        self.view.insert_action_group("spelling", Some(&fresh));
        *self.spelling.borrow_mut() = fresh;
        // Something in libspelling keeps the old adapter alive, still
        // following the buffer and checking it: dispose it now, which stops
        // both, before its tag goes (it would touch the freed tag).
        // SAFETY: nothing of ours uses `old` after this; libspelling's own
        // references are released by its dispose.
        unsafe { old.run_dispose() };
        drop(old);
        let table = self.buffer.tag_table();
        if let Some(tag) = old_tag {
            table.remove(&tag);
        }
        let no_spell = self.styler.tags.no_spell.clone();
        table.remove(&no_spell);
        table.add(&no_spell);
        let model = self.model.borrow();
        for r in &model.prepared.layout.spell_exempt {
            if r.end <= model.source.text().len() {
                let a = self.buffer.iter_at_offset(model.source.to_buffer(r.start));
                let b = self.buffer.iter_at_offset(model.source.to_buffer(r.end));
                self.buffer.apply_tag(&no_spell, &a, &b);
            }
        }
        drop(model);
        self.update_spelling_menu();
    }

    /// Make this view a table cell: its edits go to `hooks` and it keeps no
    /// undo of its own (the document's covers them).
    pub fn set_cell_hooks(&self, hooks: CellHooks) {
        *self.cell.borrow_mut() = Some(hooks);
        self.update_spelling_menu();
    }

    /// Follow a link from the document, or from one of its cells.
    pub fn follow_link(&self, url: &str) {
        if let Some(f) = self.on_follow_link.borrow().as_ref() {
            f(url);
        }
    }

    /// The width the visible text takes on one line, in pixels.
    pub fn natural_width(&self) -> i32 {
        let (start, end) = self.buffer.bounds();
        let shown = self.buffer.text(&start, &end, false);
        shown.lines().map(|line| self.view.text_width(line)).max().unwrap_or(0)
    }

    /// The grids, in source order (diagnostics and tests).
    pub fn table_grids(&self) -> Vec<Rc<TableGrid>> {
        self.grids.borrow().iter().map(|(_, g)| Rc::clone(g)).collect()
    }

    /// The table starting at source offset `start`, if the layout is current.
    fn table_at(&self, start: usize) -> Option<crate::layout::Table> {
        let model = self.model.borrow();
        if model.prepared.layout.length != model.source.text().len() {
            return None;
        }
        model.prepared.layout.tables.iter().find(|t| t.range.start == start).cloned()
    }

    /// Apply an edit of cell (`row`, `column`) of the table at `start`: its
    /// source `range` replaced by `inserted`. Waits for the layout when a
    /// parse is still on its way, so the cell's range is the current one.
    pub fn apply_cell_edit(&self, start: usize, row: usize, column: usize, range: Range<usize>, inserted: &str) {
        let edit = CellEdit { start, row, column, range, inserted: inserted.to_string() };
        if !self.pending_cell_edits.borrow().is_empty() || self.table_at(start).is_none() {
            self.pending_cell_edits.borrow_mut().push(edit);
            return;
        }
        self.apply_one_cell_edit(edit);
    }

    fn apply_one_cell_edit(&self, edit: CellEdit) -> bool {
        let Some(table) = self.table_at(edit.start) else { return false };
        if edit.row >= table.rows.len() || edit.column >= table.rows[edit.row].len() {
            return true;
        }
        let e = crate::table_source::cell_edit(&table, edit.row, edit.column, edit.range, &edit.inserted);
        self.replace(e.range, &e.insert);
        true
    }

    /// Apply cell edits that waited for this layout, as far as it allows.
    fn flush_cell_edits(&self) {
        loop {
            let Some(edit) = (!self.pending_cell_edits.borrow().is_empty()).then(|| self.pending_cell_edits.borrow_mut().remove(0))
            else {
                return;
            };
            // The first edit of a burst lands against the current layout; the
            // rest wait for the parse it causes (a synchronous one runs inside
            // `replace`, and comes back here).
            let start = edit.start;
            if self.table_at(start).is_none() {
                self.pending_cell_edits.borrow_mut().insert(0, edit);
                return;
            }
            self.apply_one_cell_edit(edit);
        }
    }

    /// Run a table command from cell (`row`, `column`) of the table at
    /// `start`. Whether it changed anything.
    pub fn perform_table_command(&self, start: usize, command: crate::table_source::Command, row: usize, column: usize) -> bool {
        let Some(table) = self.table_at(start) else { return false };
        let Some(edit) = command.edit(&table, &self.text(), row, column) else { return false };
        self.replace(edit.range, &edit.insert);
        true
    }

    /// Show the source of the table at `start` (from one of its cells).
    pub fn reveal_table(&self, start: usize) {
        let Some(table) = self.table_at(start) else { return };
        self.view.grab_focus();
        self.set_caret(table.range.start);
        self.set_revealed_units(vec![table.range], false);
    }

    /// Give every table not revealed a grid on an anchor before its first
    /// character, and drop the grids of tables that went or are revealed.
    fn sync_tables(&self) {
        if !self.loaded.get() || self.cell.borrow().is_some() {
            return;
        }
        let (wanted, len) = {
            let model = self.model.borrow();
            let len = model.source.text().len();
            if model.prepared.layout.length != len {
                return;
            }
            let wanted: Vec<crate::layout::Table> =
                model.prepared.layout.tables.iter().filter(|t| !model.is_revealed(&t.range) && t.range.end <= len).cloned().collect();
            (wanted, len)
        };
        let _ = len;
        let anchor_text = self.model.borrow().source.text().to_string();
        let anchor_at = |t: &crate::layout::Table| crate::table_source::anchor_offset(&anchor_text, t);
        // Drop the grids whose anchor an edit removed, or whose table went.
        let mut keep: Vec<(gtk4::TextChildAnchor, Rc<TableGrid>, usize)> = Vec::new();
        for (anchor, grid) in self.grids.borrow_mut().drain(..) {
            if anchor.is_deleted() {
                continue;
            }
            let offset = self.buffer.iter_at_child_anchor(&anchor).offset();
            let at = self.model.borrow().source.to_source(offset);
            if wanted.iter().any(|t| anchor_at(t) == at) && !keep.iter().any(|k| k.2 == at) {
                keep.push((anchor, grid, at));
            } else {
                self.syncing.set(true);
                let mut a = self.buffer.iter_at_offset(offset);
                let mut b = self.buffer.iter_at_offset(offset + 1);
                self.buffer.delete(&mut a, &mut b);
                self.syncing.set(false);
                self.model.borrow_mut().source.remove_anchor(at);
            }
        }
        let me = self.me.upgrade().expect("a live view");
        let mut inserted = false;
        for table in &wanted {
            if keep.iter().any(|k| k.2 == anchor_at(table)) {
                continue;
            }
            inserted = true;
            let start = anchor_at(table);
            self.syncing.set(true);
            let mut iter = self.buffer.iter_at_offset(self.model.borrow().source.to_buffer(start));
            let anchor = self.buffer.create_child_anchor(&mut iter);
            self.syncing.set(false);
            self.model.borrow_mut().source.add_anchor(start);
            let after = self.model.borrow().source.to_buffer(start);
            let tag = self.anchor_line_tag(&anchor_text, start).clone();
            self.buffer.apply_tag(&tag, &self.buffer.iter_at_offset(after - 1), &self.buffer.iter_at_offset(after));
            let grid = TableGrid::new(&me);
            self.view.add_child_at_anchor(&grid.widget, &anchor);
            keep.push((anchor, grid, start));
        }
        keep.sort_by_key(|k| k.2);
        if inserted {
            self.reset_spelling();
        }
        let editable = self.is_editable();
        let row_height = self.table_row_height.get();
        {
            let model = self.model.borrow();
            let (text, theme, width) = (model.source.text(), &model.theme, model.column_width);
            for (_, grid, at) in &keep {
                if let Some(table) = wanted.iter().find(|t| anchor_at(t) == *at) {
                    grid.update(table, text, theme, width, editable, row_height);
                }
            }
        }
        *self.grids.borrow_mut() = keep.into_iter().map(|(a, g, _)| (a, g)).collect();
        self.view.queue_draw();
    }

    /// Build the grids near the screen and drop those far from it, once the
    /// frame that showed `visible` is done.
    fn grids_on_screen(&self, visible: Range<usize>) {
        if self.grids.borrow().is_empty() || self.grids_pending.replace(true) {
            return;
        }
        let me = self.me.clone();
        glib::idle_add_local_once(move || {
            let Some(doc) = me.upgrade() else { return };
            doc.grids_pending.set(false);
            let span = visible.len().max(4096);
            let near = visible.start.saturating_sub(span)..visible.end + span;
            let far = visible.start.saturating_sub(4 * span)..visible.end + 4 * span;
            let editable = doc.is_editable();
            let grids = doc.table_grids();
            let model = doc.model.borrow();
            let (text, theme, width) = (model.source.text(), &model.theme, model.column_width);
            for grid in grids {
                let at = grid.start.get();
                if near.contains(&at) {
                    grid.build(text, theme, width, editable);
                    if let Some(h) = grid.row_height() {
                        doc.table_row_height.set(h);
                    }
                } else if !far.contains(&at) {
                    grid.unbuild(doc.table_row_height.get(), width);
                }
            }
        });
    }

    // MARK: Images

    /// The document's file: relative image addresses resolve against its
    /// folder, and pasted images are saved beside it.
    pub fn set_document_path(&self, path: Option<PathBuf>) {
        *self.document_path.borrow_mut() = path;
        self.model.borrow_mut().images.clear();
        self.request_images();
    }

    pub fn image_state(&self, address: &str) -> Option<ImageState> {
        self.model.borrow().images.get(address).map(|i| i.state)
    }

    /// Start loading every block image not yet requested, off the main
    /// thread; each restyles its lines when it lands.
    fn request_images(&self) {
        let path = self.document_path.borrow().clone();
        let wanted: Vec<(String, Option<images::ImageSource>)> = {
            let mut model = self.model.borrow_mut();
            let mut wanted = Vec::new();
            let addresses: Vec<String> = model.prepared.layout.block_images.iter().map(|i| i.url.clone()).collect();
            for address in addresses {
                if model.images.contains_key(&address) {
                    continue;
                }
                model.images.insert(address.clone(), Image { state: ImageState::Loading, texture: None });
                let source = images::image_source(&address, path.as_deref());
                wanted.push((address, source));
            }
            wanted
        };
        if wanted.is_empty() {
            return;
        }
        let (bytes, pixels) = (self.max_image_bytes.get(), self.max_image_pixels.get());
        let (sender, receiver) = async_channel::unbounded();
        std::thread::spawn(move || {
            for (address, source) in wanted {
                let decoded = source.and_then(|s| images::load(&s, bytes, pixels));
                if sender.send_blocking((address, decoded)).is_err() {
                    return;
                }
            }
        });
        let me = self.me.clone();
        glib::spawn_future_local(async move {
            while let Ok((address, decoded)) = receiver.recv().await {
                let Some(doc) = me.upgrade() else { return };
                doc.image_loaded(&address, decoded);
            }
        });
    }

    fn image_loaded(&self, address: &str, decoded: Option<images::Decoded>) {
        let texture = decoded.map(|d| d.texture());
        let state = if texture.is_some() { ImageState::Loaded } else { ImageState::Failed };
        self.model.borrow_mut().images.insert(address.to_string(), Image { state, texture });
        self.restyle_images(|image| image.url == address);
    }

    fn restyle_images(&self, matches: impl Fn(&BlockImage) -> bool) {
        let ranges: Vec<Range<usize>> = {
            let model = self.model.borrow();
            let len = model.source.text().len();
            model
                .prepared
                .layout
                .block_images
                .iter()
                .filter(|i| matches(i) && i.range.end <= len)
                .map(|i| i.range.clone())
                .collect()
        };
        for range in ranges {
            self.restyle(range);
        }
    }

    /// Paste an image (a screenshot, from an image viewer or a browser):
    /// save it as a PNG in an "images" folder beside the document and link
    /// it on its own paragraph. Returns false, writing nothing, when editing
    /// is off or the document has no folder.
    pub fn paste_image(&self, texture: &gdk::Texture) -> bool {
        let Some(document) = self.document_path.borrow().clone() else { return false };
        if !self.is_editable() || !self.is_loaded() {
            return false;
        }
        let Some(folder) = document.parent().map(|p| p.join("images")) else { return false };
        let stamp = glib::DateTime::now_local()
            .and_then(|t| t.format("%Y%m%d-%H%M%S"))
            .map_or_else(|_| "image".to_string(), |s| s.to_string());
        let name = images::pasted_name(&document, &folder, &stamp);
        if std::fs::create_dir_all(&folder).is_err() || texture.save_to_png(folder.join(&name)).is_err() {
            self.view.error_bell();
            return false;
        }
        let at = self.selection();
        let (before, after) = images::paragraph_padding(self.model.borrow().source.text(), at.clone());
        let link = format!("![](images/{name})");
        self.replace(at.clone(), &format!("{before}{link}{after}"));
        self.set_caret(at.start + before.len() + link.len());
        true
    }

    /// The column changed width: pictures scale with it.
    fn column_changed(&self, width: i32) {
        if self.model.borrow().column_width == width {
            return;
        }
        self.model.borrow_mut().column_width = width;
        // Not from inside the allocation this comes from: restyling changes
        // the layout being allocated.
        let me = self.me.clone();
        glib::idle_add_local_once(move || {
            let Some(doc) = me.upgrade() else { return };
            doc.sync_tables();
            let model = Rc::clone(&doc.model);
            doc.restyle_images(|image| {
                model.borrow().images.get(&image.url).is_some_and(|i| i.state == ImageState::Loaded)
            });
        });
    }

    // MARK: Reader

    /// The headings of the current layout.
    pub fn headings(&self) -> Vec<Heading> {
        self.model.borrow().prepared.layout.headings.clone()
    }

    /// Scroll so source offset `at` is at the top. GTK scrolls to a mark
    /// once the lines up to it are laid out.
    pub fn scroll_to_offset(&self, at: usize) {
        // The very top includes the view's top margin, which the mark's line
        // does not.
        if at == 0 {
            if let Some(adj) = self.view.vadjustment() {
                adj.set_value(0.0);
            }
            return;
        }
        let offset = {
            let model = self.model.borrow();
            model.source.to_buffer(at.min(model.source.text().len()))
        };
        let iter = self.buffer.iter_at_offset(offset);
        self.buffer.move_mark(&self.scroll_mark, &iter);
        self.view.scroll_to_mark(&self.scroll_mark, 0.0, true, 0.0, 0.0);
    }

    /// Source offset of the first character at the top of the visible area.
    pub fn top_offset(&self) -> usize {
        let visible = self.view.visible_rect();
        // One pixel below the edge, so the line above does not claim it.
        let y = visible.y() + 1;
        let iter = self
            .view
            .iter_at_location(self.view.left_margin() + 1, y)
            .unwrap_or_else(|| self.view.line_at_y(y).0);
        self.model.borrow().source.to_source(iter.offset())
    }

    /// Scroll progress, 0…1.
    pub fn scroll_fraction(&self) -> f64 {
        let Some(adj) = self.view.vadjustment() else { return 0.0 };
        let max = adj.upper() - adj.page_size();
        if max > 0.0 { (adj.value() / max).clamp(0.0, 1.0) } else { 0.0 }
    }

    /// Scroll to progress `fraction` (a legacy reading position).
    pub fn scroll_to_fraction(&self, fraction: f64) {
        let Some(adj) = self.view.vadjustment() else { return };
        adj.set_value((adj.upper() - adj.page_size()).max(0.0) * fraction.clamp(0.0, 1.0));
    }

    /// Highlight find's matches, `current` more strongly.
    pub fn set_find(&self, matches: Vec<Range<usize>>, current: Option<usize>) {
        let (start, end) = self.buffer.bounds();
        self.buffer.remove_tag(&self.find_tag, &start, &end);
        self.buffer.remove_tag(&self.find_current_tag, &start, &end);
        *self.find_matches.borrow_mut() = matches;
        self.find_current.set(current);
        let len = self.model.borrow().source.text().len();
        self.tag_matches(&self.model.borrow(), 0..len);
    }

    /// Select source `range` and scroll it into view, a third of the way down.
    pub fn show_match(&self, range: Range<usize>) {
        self.select(range.clone());
        let offset = self.model.borrow().source.to_buffer(range.start);
        let iter = self.buffer.iter_at_offset(offset);
        self.buffer.move_mark(&self.scroll_mark, &iter);
        self.view.scroll_to_mark(&self.scroll_mark, 0.1, true, 0.0, 0.3);
    }

    fn tag_matches(&self, model: &Model, range: Range<usize>) {
        let matches = self.find_matches.borrow();
        let from = matches.partition_point(|m| m.end <= range.start);
        let current = self.find_current.get();
        for (i, m) in matches.iter().enumerate().skip(from) {
            if m.start >= range.end {
                break;
            }
            let start = self.buffer.iter_at_offset(model.source.to_buffer(m.start));
            let end = self.buffer.iter_at_offset(model.source.to_buffer(m.end));
            let tag = if current == Some(i) { &self.find_current_tag } else { &self.find_tag };
            self.buffer.apply_tag(tag, &start, &end);
        }
    }

    fn color_find_tags(&self) {
        let theme = &self.model.borrow().theme;
        let mut all = theme.review_highlight;
        all.set_alpha(all.alpha() * 0.7);
        self.find_tag.set_background_rgba(Some(&all));
        let mut current = theme.accent;
        current.set_alpha(0.35);
        self.find_current_tag.set_background_rgba(Some(&current));
    }

    fn restyle_all(&self) {
        let len = self.model.borrow().source.text().len();
        if len <= SYNC_PARSE_LIMIT {
            self.restyle(0..len);
        } else {
            self.restyle(0..FIRST_SCREEN.min(len));
            self.style_lazily(std::iter::once(FIRST_SCREEN.min(len)..len).collect(), false);
        }
    }

    // MARK: Caret and deletes

    /// Whether source byte `byte` is hidden markup right now (what is on
    /// screen: the buffer's tags travel with the text between parses).
    /// Whether source byte `byte` is hidden right now.
    pub fn hidden_at(&self, byte: usize) -> bool {
        self.is_hidden(&self.model.borrow(), byte)
    }

    /// Whether source byte `byte` carries the tag named `name`.
    pub fn has_tag_at(&self, byte: usize, name: &str) -> bool {
        let model = self.model.borrow();
        let Some(tag) = self.buffer.tag_table().lookup(name) else { return false };
        self.buffer.iter_at_offset(model.source.to_buffer(byte)).has_tag(&tag)
    }

    /// How long the last parse result took to install (diff, swaps, restyle).
    pub fn last_apply(&self) -> Duration {
        self.last_apply.get()
    }

    /// How many parse results have been installed since loading.
    pub fn parses_applied(&self) -> u64 {
        self.applied.get()
    }

    /// Whether styling of a large document is still catching up.
    pub fn is_styling(&self) -> bool {
        self.tagger.borrow().is_some()
    }

    fn is_hidden(&self, model: &Model, byte: usize) -> bool {
        byte < model.source.text().len()
            && self.buffer.iter_at_offset(model.source.to_buffer(byte)).has_tag(&self.styler.tags.hidden)
    }

    fn caret_moved(&self, offset: i32) {
        if self.syncing.get() || self.snapping.get() || self.editing.get() {
            return;
        }
        let forward = offset >= self.prev_caret.get();
        if self.buffer.has_selection() || self.model.borrow().show_all {
            self.prev_caret.set(offset);
            self.selection_changed();
            return;
        }
        let target = {
            let model = self.model.borrow();
            match self.past_grid(&model, offset, forward) {
                Some(target) => Some(target),
                None => {
                    let at = model.source.to_source(offset);
                    let snapped = edit_rules::snap_caret(at, forward, model.source.text(), |b| self.is_hidden(&model, b));
                    (snapped != at).then(|| model.source.to_buffer(snapped))
                }
            }
        };
        let offset = match target {
            Some(target) => {
                self.snapping.set(true);
                self.buffer.place_cursor(&self.buffer.iter_at_offset(target));
                self.snapping.set(false);
                target
            }
            None => offset,
        };
        self.prev_caret.set(offset);
        self.selection_changed();
        self.update_review_focus();
    }

    /// A caret beside a grid's anchor would type into the table's hidden
    /// source: it passes the table as one block instead, as on macOS. The
    /// buffer offset to move to, if `offset` is there.
    fn past_grid(&self, model: &Model, offset: i32, forward: bool) -> Option<i32> {
        let anchor = if model.source.is_anchor(offset) {
            offset
        } else if offset > 0 && model.source.is_anchor(offset - 1) {
            offset - 1
        } else {
            return None;
        };
        let start = model.source.to_source(anchor);
        let text = model.source.text();
        let table = model.prepared.layout.tables.iter().find(|t| crate::table_source::anchor_offset(text, t) == start)?;
        if !forward {
            return Some((anchor - 1).max(0));
        }
        let end = if text.as_bytes().get(table.range.end) == Some(&b'\n') { table.range.end + 1 } else { table.range.end };
        Some(model.source.to_buffer(end))
    }

    /// Backspace (`forward` false) or Delete over hidden markup: apply the
    /// delete rules. True when handled here (the view must not delete).
    fn retarget(&self, forward: bool) -> bool {
        if !self.is_editable() || self.buffer.has_selection() || self.model.borrow().show_all {
            return false;
        }
        let action = {
            let model = self.model.borrow();
            let text = model.source.text();
            let caret = model.source.to_source(self.buffer.cursor_position());
            let target = if forward {
                if caret >= text.len() {
                    return false;
                }
                caret..next_boundary(text, caret)
            } else {
                if caret == 0 {
                    return false;
                }
                prev_boundary(text, caret)..caret
            };
            edit_rules::retarget_delete(target, caret, text, |b| self.is_hidden(&model, b))
        };
        match action {
            DeleteAction::Allow => false,
            DeleteAction::Ignore => true,
            DeleteAction::Replace(range) => {
                let start = range.start;
                self.replace(range, "");
                self.set_caret(start);
                true
            }
        }
    }

    // MARK: Reveal

    /// Units containing the selection. A caret at a unit's end counts as
    /// inside it, unless the unit ends with a newline (a block): then the
    /// caret is already on the next line.
    fn units_enclosing_selection(&self) -> Vec<Range<usize>> {
        let selection = self.selection();
        let model = self.model.borrow();
        let text = model.source.text();
        model
            .prepared
            .layout
            .reveal_units()
            .into_iter()
            .filter(|unit| {
                if !encloses(unit, &selection) {
                    return false;
                }
                let at_block_end = selection.is_empty()
                    && selection.start == unit.end
                    && !unit.is_empty()
                    && text.as_bytes()[unit.end - 1] == b'\n';
                !at_block_end
            })
            .collect()
    }

    /// Show the markup of the unit(s) enclosing the selection (on), or hide it again (off).
    pub fn reveal(&self, on: bool) {
        let units = if on { self.units_enclosing_selection() } else { Vec::new() };
        self.set_revealed_units(units, false);
    }

    pub fn is_revealing(&self) -> bool {
        self.revealing.get()
    }

    pub fn toggle_show_all_markup(&self) {
        {
            let mut model = self.model.borrow_mut();
            model.show_all = !model.show_all;
        }
        self.restyle_all();
        self.sync_tables();
    }

    fn set_revealed_units(&self, units: Vec<Range<usize>>, keep_revealing: bool) {
        self.revealing.set(keep_revealing || !units.is_empty());
        let touched = {
            let mut model = self.model.borrow_mut();
            if units == model.revealed {
                return;
            }
            let touched = units.iter().chain(&model.revealed).cloned().reduce(|a, b| a.start.min(b.start)..a.end.max(b.end));
            model.revealed = units;
            touched
        };
        if let Some(touched) = touched {
            self.restyle(touched);
        }
        self.sync_tables();
    }

    /// Selection moved: a reveal ends once the selection leaves every revealed unit.
    fn selection_changed(&self) {
        if !self.revealing.get() || self.editing.get() {
            return;
        }
        let current = self.units_enclosing_selection();
        let keep = self.model.borrow().revealed.iter().any(|u| current.contains(u));
        if !keep {
            self.set_revealed_units(Vec::new(), false);
        }
    }

    /// After a re-parse, revealed units are re-found around the selection
    /// (their ranges moved with the edit).
    fn update_revealed_units(&self) {
        if self.revealing.get() {
            let units = self.units_enclosing_selection();
            self.set_revealed_units(units, true);
        }
    }

    // MARK: Commands

    /// Wrap the selection in `marker`, or unwrap it.
    pub fn wrap_selection(&self, marker: &str) {
        if !self.is_editable() {
            return;
        }
        let selection = self.selection();
        let Some((edits, after)) = edit_rules::toggle_wrap(selection, marker, &self.text()) else { return };
        self.buffer.begin_user_action();
        for edit in edits.iter().rev() {
            self.replace(edit.range.clone(), &edit.insert);
        }
        self.buffer.end_user_action();
        self.select(after);
    }

    /// Check or uncheck task item `index`: allowed while reading too.
    pub fn toggle_task(&self, index: usize) {
        if !self.loaded.get() {
            return;
        }
        let (box_range, done) = {
            let model = self.model.borrow();
            let Some(item) = model.prepared.layout.list_items.get(index) else { return };
            let (Some(done), Some(checkbox)) = (item.task, item.checkbox.clone()) else { return };
            (checkbox, done)
        };
        let caret = self.selection();
        self.replace(box_range, if done { "[ ]" } else { "[x]" });
        self.select(caret);
    }

    /// The kind of the top-level block the caret is in (None between blocks).
    fn block_kind_at_caret(&self) -> Option<String> {
        let caret = self.caret_source();
        let model = self.model.borrow();
        let blocks = &model.prepared.layout.blocks;
        let i = blocks.partition_point(|b| b.range.end < caret);
        blocks.get(i).filter(|b| b.range.start <= caret).map(|b| b.kind.clone())
    }

    /// Return on a list item's first line or a quoted line: continue it with
    /// the same prefix (the next number; an unchecked box), or end it when the
    /// line is empty. False if the caret is on neither.
    fn continue_list_or_quote(&self) -> bool {
        if !self.is_editable() || self.buffer.has_selection() {
            return false;
        }
        let caret = self.caret_source();
        let edit = {
            let model = self.model.borrow();
            let text = model.source.text();
            let layout = &model.prepared.layout;
            let line = line_range(text, caret);
            let line_end = if text[line.clone()].ends_with('\n') { line.end - 1 } else { line.end };
            let quote = layout.quote_lines.iter().find(|q| line.contains(&q.prefix.start));
            let item = layout.list_items.iter().find(|i| line.contains(&i.marker.start));
            if item.is_none() && quote.is_none() {
                return false;
            }
            let prefix_end = item.map_or_else(|| quote.unwrap().prefix.end, |i| i.marker.end);
            if caret < prefix_end {
                return false;
            }
            let content = &text[prefix_end..line_end.max(prefix_end)];
            if content.trim_matches(|c| c == ' ' || c == '\t').is_empty() {
                let start = quote.map_or_else(|| item.unwrap().marker.start, |q| q.prefix.start);
                (start..prefix_end, String::new(), start)
            } else {
                let mut next = quote.map_or(String::new(), |q| text[q.prefix.clone()].to_string());
                if let Some(item) = item {
                    next += &text[item.marker.start..item.bullet.start];
                    let mut bullet = text[item.bullet.clone()].to_string();
                    if item.ordered {
                        if let Some(delimiter) = bullet.pop() {
                            if let Ok(n) = bullet.parse::<u64>() {
                                bullet = format!("{}{delimiter}", n + 1);
                            } else {
                                bullet.push(delimiter);
                            }
                        }
                    }
                    next += &bullet;
                    next += " ";
                    if item.task.is_some() {
                        next += "[ ] ";
                    }
                }
                let insert = format!("\n{next}");
                let after = caret + insert.len();
                (caret..caret, insert, after)
            }
        };
        let (range, insert, caret_after) = edit;
        self.replace(range, &insert);
        self.set_caret(caret_after);
        true
    }

    /// Return in a paragraph or heading starts a new paragraph ("\n\n"): a
    /// single "\n" would be a soft break and reflow away. Elsewhere it stays
    /// a plain newline.
    pub fn insert_newline(&self) -> bool {
        if self.continue_list_or_quote() {
            return true;
        }
        if !self.is_editable() || !matches!(self.block_kind_at_caret().as_deref(), Some("paragraph" | "heading")) {
            return false;
        }
        let at = self.selection();
        let start = at.start;
        self.replace(at, "\n\n");
        self.set_caret(start + 2);
        true
    }

    /// Shift+Return breaks the line within a paragraph: a Markdown hard break.
    pub fn insert_line_break(&self) -> bool {
        if !self.is_editable() || !matches!(self.block_kind_at_caret().as_deref(), Some("paragraph" | "heading")) {
            return false;
        }
        let at = self.selection();
        let start = at.start;
        self.replace(at, "\\\n");
        self.set_caret(start + 2);
        true
    }

    // MARK: Clipboard

    /// The source range to copy for `selection`: the selection plus any
    /// markup hidden at its edges (selecting a bold word copies "**word**"),
    /// so the clipboard gets Markdown, not the rendered text.
    pub fn copy_range(&self, selection: Range<usize>) -> Range<usize> {
        let model = self.model.borrow();
        if model.show_all || selection.is_empty() {
            return selection;
        }
        let text = model.source.text();
        let hidden = |b: usize| self.is_hidden(&model, b);
        let (mut start, mut end) = (selection.start, selection.end);
        while start > 0 && hidden(start - 1) {
            start = prev_boundary(text, start);
        }
        while end < text.len() {
            if hidden(end) {
                end = next_boundary(text, end);
                continue;
            }
            // A collapsed line right after (a closing fence): take it, newline and all.
            if text.as_bytes()[end] == b'\n' && end + 1 < text.len() && hidden(end + 1) {
                let run = edit_rules::hidden_run(end + 1, text.len(), hidden);
                if text.as_bytes()[run.end - 1] == b'\n' {
                    end = run.end;
                    continue;
                }
            }
            break;
        }
        start..end
    }

    fn copy(&self) {
        let range = self.copy_range(self.selection());
        if range.is_empty() {
            return;
        }
        let text = self.model.borrow().source.text()[range].to_string();
        self.view.clipboard().set_text(&text);
    }

    fn cut(&self) {
        self.copy();
        if self.is_editable() {
            let range = self.copy_range(self.selection());
            let start = range.start;
            self.replace(range, "");
            self.set_caret(start);
        }
    }

    // MARK: Input

    fn connect_keys(&self) {
        let keys = gtk4::EventControllerKey::new();
        keys.set_propagation_phase(gtk4::PropagationPhase::Capture);
        let me = self.me.clone();
        keys.connect_key_pressed(move |_, key, _, state| {
            let Some(doc) = me.upgrade() else { return glib::Propagation::Proceed };
            if doc.preedit.get() {
                return glib::Propagation::Proceed;
            }
            // In the capture phase this sees the keys of whatever has focus
            // inside the view too: a table cell, a card's reply field. Those
            // are theirs.
            if !doc.view.has_focus() {
                return glib::Propagation::Proceed;
            }
            let mods = state & (gdk::ModifierType::CONTROL_MASK | gdk::ModifierType::SHIFT_MASK | gdk::ModifierType::ALT_MASK);
            let ctrl = gdk::ModifierType::CONTROL_MASK;
            let shift = gdk::ModifierType::SHIFT_MASK;
            let alt = gdk::ModifierType::ALT_MASK;
            if let Some(hooks) = doc.cell.borrow().as_ref() {
                let cell_key = match (key.to_lower(), mods) {
                    (gdk::Key::Tab, m) if m.is_empty() => Some(CellKey::Next),
                    (gdk::Key::ISO_Left_Tab, _) | (gdk::Key::Tab, _) if mods == shift => Some(CellKey::Previous),
                    (gdk::Key::Return | gdk::Key::KP_Enter, m) if m.is_empty() => Some(CellKey::Down),
                    (gdk::Key::z, m) if m == ctrl => Some(CellKey::Undo),
                    (gdk::Key::z, m) if m == ctrl | shift => Some(CellKey::Redo),
                    (gdk::Key::y, m) if m == ctrl => Some(CellKey::Redo),
                    (gdk::Key::apostrophe, m) if m == ctrl => Some(CellKey::Reveal),
                    (k, m) if m == alt | shift => {
                        k.name().and_then(|n| crate::table_source::Command::for_key(&n, true)).map(CellKey::Command)
                    }
                    _ => None,
                };
                if let Some(cell_key) = cell_key {
                    return if (hooks.on_key)(cell_key) { glib::Propagation::Stop } else { glib::Propagation::Proceed };
                }
            }
            let key = key.to_lower();
            let handled = match (key, mods) {
                (gdk::Key::Return | gdk::Key::KP_Enter, m) if m.is_empty() => doc.insert_newline(),
                (gdk::Key::Return | gdk::Key::KP_Enter, m) if m == shift => doc.insert_line_break(),
                (gdk::Key::Escape, m) if m.is_empty() && doc.revealing.get() => {
                    doc.reveal(false);
                    true
                }
                (gdk::Key::apostrophe, m) if m == ctrl => {
                    doc.reveal(!doc.revealing.get());
                    true
                }
                (gdk::Key::m, m) if m == ctrl | alt => {
                    doc.toggle_show_all_markup();
                    true
                }
                (gdk::Key::b, m) if m == ctrl => {
                    doc.wrap_selection("**");
                    true
                }
                (gdk::Key::m, m) if m == ctrl | shift => doc.open_composer(false),
                (gdk::Key::e, m) if m == ctrl | shift => doc.open_composer(true),
                (gdk::Key::F8, m) if m.is_empty() => doc.move_to_thread(true),
                (gdk::Key::F8, m) if m == shift => doc.move_to_thread(false),
                (gdk::Key::i, m) if m == ctrl => {
                    doc.wrap_selection("*");
                    true
                }
                (gdk::Key::z, m) if m == ctrl => {
                    doc.undo();
                    true
                }
                (gdk::Key::z, m) if m == ctrl | shift => {
                    doc.redo();
                    true
                }
                (gdk::Key::y, m) if m == ctrl => {
                    doc.redo();
                    true
                }
                _ => false,
            };
            if handled { glib::Propagation::Stop } else { glib::Propagation::Proceed }
        });
        self.view.add_controller(keys);
    }

    /// Source offset under widget point (`x`, `y`), and the buffer point.
    fn source_at(&self, x: f64, y: f64) -> Option<(usize, (i32, i32))> {
        let (bx, by) = self.view.window_to_buffer_coords(gtk4::TextWindowType::Widget, x as i32, y as i32);
        // Not below the text (`styler::NO_ROOM_BELOW`).
        let (end_y, end_h) = self.view.line_yrange(&self.buffer.end_iter());
        if by >= end_y + end_h {
            return None;
        }
        let iter = self.view.iter_at_location(bx, by)?;
        Some((self.model.borrow().source.to_source(iter.offset()), (bx, by)))
    }

    /// The link destination at source offset `at`, if any.
    fn link_at(&self, at: usize) -> Option<String> {
        let model = self.model.borrow();
        let layout = &model.prepared.layout;
        model.prepared.styles.query(&(at..at + 1)).map(|i| &layout.styles[i]).find_map(|run| match &run.style {
            Style::Link { url } | Style::Autolink { url } if run.range.contains(&at) => Some(url.clone()),
            _ => None,
        })
    }

    /// Whether buffer point `y` is below the text, on a view whose last line
    /// has hidden text: GTK's hit test there aborts (`styler::NO_ROOM_BELOW`).
    pub(crate) fn below_risky_end(&self, by: i32) -> bool {
        let end = self.buffer.end_iter();
        let (y, h) = self.view.line_yrange(&end);
        by >= y + h && end.line_offset() > end.visible_line_offset()
    }

    /// Clicks and drags below the end of the text, where GTK's own handling
    /// would hit-test and abort, put the caret (or the selection's end) at
    /// the end instead.
    fn guard_below_end(&self) {
        let guard = gtk4::EventControllerLegacy::new();
        guard.set_propagation_phase(gtk4::PropagationPhase::Capture);
        let me = self.me.clone();
        guard.connect_event(move |_, event| {
            let Some(doc) = me.upgrade() else { return glib::Propagation::Proceed };
            use gdk::EventType::*;
            let kind = event.event_type();
            let pressed = event.modifier_state().contains(gdk::ModifierType::BUTTON1_MASK);
            let relevant = kind == ButtonPress || kind == ButtonRelease || (kind == MotionNotify && pressed);
            let Some((x, y)) = event.position().filter(|_| relevant) else { return glib::Propagation::Proceed };
            let Some(native) = doc.view.native() else { return glib::Propagation::Proceed };
            // Event positions are the surface's; the native widget sits in it
            // at the surface transform (a client-side shadow).
            let (tx, ty) = native.surface_transform();
            let at = gtk4::graphene::Point::new((x - tx) as f32, (y - ty) as f32);
            let Some(point) = native.compute_point(&doc.view, &at) else {
                return glib::Propagation::Proceed;
            };
            if doc.over_child(point.x() as f64, point.y() as f64) {
                return glib::Propagation::Proceed;
            }
            let (_, by) = doc.view.window_to_buffer_coords(gtk4::TextWindowType::Widget, point.x() as i32, point.y() as i32);
            if !doc.below_risky_end(by) {
                return glib::Propagation::Proceed;
            }
            if kind == ButtonPress {
                let end = doc.buffer.end_iter();
                if event.modifier_state().contains(gdk::ModifierType::SHIFT_MASK) {
                    doc.buffer.move_mark(&doc.buffer.get_insert(), &end);
                } else {
                    doc.buffer.place_cursor(&end);
                }
                doc.view.grab_focus();
            } else if kind == MotionNotify {
                doc.buffer.move_mark(&doc.buffer.get_insert(), &doc.buffer.end_iter());
            }
            glib::Propagation::Stop
        });
        self.view.add_controller(guard);
    }

    /// Whether widget point (`x`, `y`) is over a table grid or a comment
    /// card: their events are theirs, not the text's.
    pub(crate) fn over_child(&self, x: f64, y: f64) -> bool {
        let mut widget = self.view.pick(x, y, gtk4::PickFlags::DEFAULT);
        while let Some(w) = widget {
            if w == *self.view.upcast_ref::<gtk4::Widget>() {
                return false;
            }
            if w.has_css_class("tvmv-table") || w.has_css_class("tvmv-card") {
                return true;
            }
            widget = w.parent();
        }
        false
    }

    fn connect_pointer(&self) {
        self.guard_below_end();
        let click = gtk4::GestureClick::new();
        click.set_button(gdk::BUTTON_PRIMARY);
        click.set_propagation_phase(gtk4::PropagationPhase::Capture);
        let me = self.me.clone();
        click.connect_pressed(move |gesture, n_press, x, y| {
            let Some(doc) = me.upgrade() else { return };
            if doc.over_child(x, y) {
                return;
            }
            if n_press == 1 {
                let Some((_, (bx, by))) = doc.source_at(x, y) else { return };
                let task = {
                    let model = doc.model.borrow();
                    doc.view.task_at(&model, bx as f64, by as f64)
                };
                if let Some(task) = task {
                    gesture.set_state(gtk4::EventSequenceState::Claimed);
                    doc.toggle_task(task);
                }
            } else if n_press == 2 {
                // After the view has selected the word.
                let me = doc.me.clone();
                glib::idle_add_local_once(move || {
                    if let Some(doc) = me.upgrade() {
                        doc.reveal(true);
                    }
                });
            }
        });
        let me = self.me.clone();
        click.connect_released(move |gesture, n_press, x, y| {
            let Some(doc) = me.upgrade() else { return };
            if doc.over_child(x, y) {
                return;
            }
            let ctrl = gesture.current_event_state().contains(gdk::ModifierType::CONTROL_MASK);
            if n_press != 1 || doc.buffer.has_selection() || (doc.is_editable() && !ctrl) {
                return;
            }
            let Some((at, _)) = doc.source_at(x, y) else { return };
            if let Some(url) = doc.link_at(at) {
                doc.follow_link(&url);
            }
        });
        self.view.add_controller(click);

        // A hand over links when following them is one click away.
        let motion = gtk4::EventControllerMotion::new();
        let me = self.me.clone();
        motion.connect_motion(move |_, x, y| {
            let Some(doc) = me.upgrade() else { return };
            if doc.over_child(x, y) {
                return;
            }
            let over_link = doc.source_at(x, y).and_then(|(at, _)| doc.link_at(at)).is_some();
            let name = if over_link && !doc.is_editable() { "pointer" } else { "text" };
            doc.view.set_cursor_from_name(Some(name));
        });
        self.view.add_controller(motion);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_text_swaps_only_soft_breaks() {
        let text = "one\ntwo\n\nthree";
        assert_eq!(display_text(text, &[3]), "one two\n\nthree");
        assert_eq!(display_text(text, &[]), text);
    }
}
