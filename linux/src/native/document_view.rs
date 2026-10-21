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
use std::ops::Range;
use std::rc::{Rc, Weak};
use std::time::{Duration, Instant};

use gtk4::prelude::*;
use gtk4::{gdk, glib, TextBuffer};

use crate::edit_rules::{self, DeleteAction};
use crate::layout::{Style, encloses};
use crate::offsets::SourceText;

use super::styler::{Prepared, Styler};
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
}

impl Model {
    pub fn is_revealed(&self, unit: &Range<usize>) -> bool {
        self.show_all || self.revealed.contains(unit)
    }
}

type Callback = Box<dyn Fn()>;
type LinkCallback = Box<dyn Fn(&str)>;

pub struct DocumentView {
    pub view: TvmvView,
    pub buffer: TextBuffer,
    pub model: Rc<RefCell<Model>>,
    styler: Styler,
    undo: RefCell<UndoStack>,
    css: gtk4::CssProvider,
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
        let styler = Styler::new(&buffer, &theme);
        let model = Rc::new(RefCell::new(Model {
            source: SourceText::new(String::new()),
            prepared: Rc::new(Prepared::default()),
            theme,
            revealed: Vec::new(),
            show_all: false,
            partial: false,
        }));
        view.set_model(Rc::clone(&model));
        let css = gtk4::CssProvider::new();
        if let Some(display) = gdk::Display::default() {
            gtk4::style_context_add_provider_for_display(&display, &css, gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
        let doc = Rc::new_cyclic(|me| DocumentView {
            view,
            buffer,
            model,
            styler,
            undo: RefCell::new(UndoStack::default()),
            css,
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
        });
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
        self.view.set_cursor_visible(editable);
    }

    pub fn is_loaded(&self) -> bool {
        self.loaded.get()
    }

    pub fn show_all_markup(&self) -> bool {
        self.model.borrow().show_all
    }

    fn apply_css(&self) {
        self.css.load_from_string(&self.model.borrow().theme.css());
    }

    pub fn set_theme(&self, theme: NativeTheme) {
        if self.model.borrow().theme == theme {
            return;
        }
        self.styler.set_theme(&theme);
        self.model.borrow_mut().theme = theme;
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
        self.view.set_on_column(move |x| {
            if let Some(doc) = me.upgrade() {
                doc.styler.set_column_x(x);
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
        if !self.replaying.get() {
            let caret_before = self.model.borrow().source.to_source(caret.min(offset));
            let change = Change { range: at..at, removed: String::new(), inserted: text.to_string() };
            self.undo.borrow_mut().record(change, caret_before.min(at), at + text.len());
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
        if !self.replaying.get() {
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
        self.styler.apply(&model.source, &model.prepared, range, fresh, &model.theme, &revealed, &width);
        self.view.queue_draw();
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
            let at = model.source.to_source(offset);
            let snapped = edit_rules::snap_caret(at, forward, model.source.text(), |b| self.is_hidden(&model, b));
            (snapped != at).then(|| model.source.to_buffer(snapped))
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
            let mods = state & (gdk::ModifierType::CONTROL_MASK | gdk::ModifierType::SHIFT_MASK | gdk::ModifierType::ALT_MASK);
            let ctrl = gdk::ModifierType::CONTROL_MASK;
            let shift = gdk::ModifierType::SHIFT_MASK;
            let alt = gdk::ModifierType::ALT_MASK;
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

    fn connect_pointer(&self) {
        let click = gtk4::GestureClick::new();
        click.set_button(gdk::BUTTON_PRIMARY);
        click.set_propagation_phase(gtk4::PropagationPhase::Capture);
        let me = self.me.clone();
        click.connect_pressed(move |gesture, n_press, x, y| {
            let Some(doc) = me.upgrade() else { return };
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
            let ctrl = gesture.current_event_state().contains(gdk::ModifierType::CONTROL_MASK);
            if n_press != 1 || doc.buffer.has_selection() || (doc.is_editable() && !ctrl) {
                return;
            }
            let Some((at, _)) = doc.source_at(x, y) else { return };
            if let Some(url) = doc.link_at(at) {
                if let Some(f) = doc.on_follow_link.borrow().as_ref() {
                    f(&url);
                }
            }
        });
        self.view.add_controller(click);

        // A hand over links when following them is one click away.
        let motion = gtk4::EventControllerMotion::new();
        let me = self.me.clone();
        motion.connect_motion(move |_, x, y| {
            let Some(doc) = me.upgrade() else { return };
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
