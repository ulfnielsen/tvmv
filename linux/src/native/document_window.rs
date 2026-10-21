//! A document window around the native view: toolbar, find bar, outline
//! sidebar, reading position and bookmark, print, settings and live reload.
//! The counterpart of the macOS window around `NativeDocumentView`.
//!
//! A document opens read-only; Ctrl+E makes the same view editable. The view
//! owns the text while the window is open: `Document` is brought up to date
//! from it before anything reads it (saving, the close guard, print, a
//! change on disk).
//!
//! No titlebar widget is set, so the window manager draws server-side
//! decorations, as in the web window. Icons are freedesktop names only.

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

use gtk4::prelude::*;
use gtk4::{Application, ApplicationWindow, Box as GtkBox, Button, CssProvider, Label, Orientation, Paned, glib};

use crate::chrome;
use crate::document::Document;
use crate::find::{Find, FindAction};
use crate::outline::Outline;
use crate::preview::OutlineItem;
use crate::reader::{self, LinkTarget};
use crate::reading::{self, Position, ReadingState};
use crate::settings::Settings;

use super::document_view::DocumentView;
use super::theme::NativeTheme;

pub struct DocumentWindow {
    pub window: ApplicationWindow,
    pub doc: Rc<DocumentView>,
    outline_widget: gtk4::ScrolledWindow,
    editing: Rc<dyn Fn(bool)>,
    tint: Rc<dyn Fn()>,
    /// Held so live reload keeps working: dropping it stops the watch.
    _watcher: crate::watcher::FileWatcher,
}

/// Find's state: the matches of the current query, and which is current.
#[derive(Default)]
struct Search {
    matches: Vec<std::ops::Range<usize>>,
    current: Option<usize>,
}

fn theme_for(settings: &Settings) -> NativeTheme {
    NativeTheme::from_settings(settings, crate::appearance::prefers_dark())
}

impl DocumentWindow {
    /// Open `path`. `position` overrides the saved reading position (a
    /// promoted peek window passes its own); `editing` opens it editable.
    pub fn new(app: &Application, path: &Path, settings: &Settings, position: Option<Position>, editable: bool) -> Self {
        let (width, height) = std::env::var("TVMV_WINDOW_SIZE")
            .ok()
            .and_then(|spec| {
                let (w, h) = spec.split_once('x')?;
                Some((w.parse().ok()?, h.parse().ok()?))
            })
            .unwrap_or((900, 1000));
        let window = ApplicationWindow::builder().application(app).default_width(width).default_height(height).build();

        let document = Rc::new(RefCell::new(Document::load(path).unwrap_or_else(|e| {
            eprintln!("tvmv: {}: {e}", path.display());
            Document::empty(path)
        })));
        let doc = DocumentView::new(theme_for(settings));
        doc.load(document.borrow().text().to_string());
        let saved = reading::load(path);
        let state = Rc::new(Cell::new(saved));

        // --- widgets ------------------------------------------------------

        let scroller = gtk4::ScrolledWindow::new();
        scroller.set_hscrollbar_policy(gtk4::PolicyType::Never);
        scroller.set_child(Some(&doc.view));
        scroller.set_hexpand(true);

        let outline = Rc::new(Outline::new({
            let doc = Rc::clone(&doc);
            move |anchor| scroll_to_anchor(&doc, anchor)
        }));

        let search: Rc<RefCell<Search>> = Rc::default();
        let find_slot: Rc<RefCell<Option<Rc<Find>>>> = Rc::default();
        let find = Rc::new(Find::new({
            let doc = Rc::clone(&doc);
            let search = Rc::clone(&search);
            let find_slot = Rc::clone(&find_slot);
            move |action, query| {
                let Some(find) = find_slot.borrow().clone() else { return };
                run_find(&doc, &search, &find, action, query);
            }
        }));
        *find_slot.borrow_mut() = Some(Rc::clone(&find));

        let button = |icon: &str, tip: &str| {
            let b = Button::from_icon_name(icon);
            b.set_tooltip_text(Some(tip));
            b.add_css_class("flat");
            b
        };
        let toggle_outline = button("sidebar-show-symbolic", "Toggle outline (F9)");
        let open_find = button("edit-find-symbolic", "Find (Ctrl+F)");
        let toggle_editor = gtk4::ToggleButton::new();
        toggle_editor.set_icon_name("document-edit-symbolic");
        toggle_editor.set_tooltip_text(Some("Edit (Ctrl+E)"));
        toggle_editor.add_css_class("flat");
        let progress = Label::new(Some("0%"));
        let save_bookmark = button("bookmark-new-symbolic", "Bookmark current place");
        let go_bookmark = button("go-jump-symbolic", "Go to bookmark (right-click to clear)");
        go_bookmark.set_sensitive(saved.bookmark_position().is_some());
        let print_button = button("document-print-symbolic", "Print or save as PDF (Ctrl+P)");
        let open_settings = button("preferences-system-symbolic", "Settings (Ctrl+,)");

        let toolbar = GtkBox::new(Orientation::Horizontal, 2);
        toolbar.add_css_class("tvmv-toolbar");
        toolbar.set_margin_start(4);
        toolbar.set_margin_end(4);
        toolbar.set_margin_top(2);
        toolbar.set_margin_bottom(2);
        for w in [
            toggle_outline.upcast_ref::<gtk4::Widget>(),
            open_find.upcast_ref(),
            toggle_editor.upcast_ref(),
            progress.upcast_ref(),
            save_bookmark.upcast_ref(),
            go_bookmark.upcast_ref(),
            print_button.upcast_ref(),
            open_settings.upcast_ref(),
        ] {
            toolbar.append(w);
        }

        let split = Paned::new(Orientation::Horizontal);
        split.set_start_child(Some(&outline.widget));
        split.set_end_child(Some(&scroller));
        split.set_position(240);
        split.set_resize_start_child(false);
        split.set_shrink_start_child(false);
        split.set_vexpand(true);
        outline.widget.set_visible(settings.show_outline);

        let content = GtkBox::new(Orientation::Vertical, 0);
        content.append(&toolbar);
        content.append(&find.widget);
        content.append(&split);
        window.set_child(Some(&content));

        // The chrome wears the paper. Each window tints only itself: GTK4
        // providers are display-wide, so the selectors are scoped by class.
        let scope = chrome::scope_class(crate::window::next_window_serial());
        window.add_css_class(&scope);
        let tint_provider = CssProvider::new();
        if let Some(display) = gtk4::gdk::Display::default() {
            gtk4::style_context_add_provider_for_display(
                &display,
                &tint_provider,
                gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
        }
        let tint: Rc<dyn Fn()> = Rc::new({
            let doc = Rc::clone(&doc);
            move || {
                let paper = doc.model.borrow().theme.paper;
                let rgba = chrome::Rgba {
                    red: paper.red() as f64,
                    green: paper.green() as f64,
                    blue: paper.blue() as f64,
                    alpha: 1.0,
                };
                chrome::apply_tint(&scope, rgba, &tint_provider);
            }
        });
        tint();

        // --- title, dirtiness, outline ------------------------------------

        let update_title = {
            let window = window.clone();
            let document = Rc::clone(&document);
            let doc = Rc::clone(&doc);
            move || {
                let title = document.borrow().title();
                let mode = if doc.is_editable() { " — Editing" } else { "" };
                window.set_title(Some(&format!("{title}{mode}")));
            }
        };
        update_title();
        // Bring `Document` up to date once per burst of edits, not per
        // keystroke: at 5 MB a copy and a compare cost a millisecond or two.
        let sync_pending = Rc::new(Cell::new(false));
        {
            let document = Rc::clone(&document);
            let doc_weak = Rc::downgrade(&doc);
            let update_title = update_title.clone();
            let find = Rc::clone(&find);
            let search = Rc::clone(&search);
            doc.set_on_changed(move || {
                if sync_pending.replace(true) {
                    return;
                }
                let document = Rc::clone(&document);
                let doc_weak = doc_weak.clone();
                let update_title = update_title.clone();
                let find = Rc::clone(&find);
                let search = Rc::clone(&search);
                let pending = Rc::clone(&sync_pending);
                glib::idle_add_local_once(move || {
                    pending.set(false);
                    let Some(doc) = doc_weak.upgrade() else { return };
                    document.borrow_mut().set_text(doc.text());
                    update_title();
                    // Matches move with the text: search again, in place.
                    if find.is_open() && !find.query().is_empty() {
                        refresh_find(&doc, &search, &find);
                    }
                });
            });
        }
        {
            let outline = Rc::clone(&outline);
            let doc_weak = Rc::downgrade(&doc);
            let shown: Rc<RefCell<Vec<OutlineItem>>> = Rc::default();
            let refresh = move || {
                let Some(doc) = doc_weak.upgrade() else { return };
                let items = reader::outline(&doc.headings());
                if *shown.borrow() != items {
                    outline.set_items(&items);
                    *shown.borrow_mut() = items;
                }
            };
            // A small document's layout landed in `load`, before this.
            refresh();
            doc.set_on_layout(refresh);
        }

        // --- reading position ---------------------------------------------

        {
            let doc = Rc::clone(&doc);
            let progress = progress.clone();
            let adj = scroller.vadjustment();
            let show = move |_: &gtk4::Adjustment| {
                progress.set_text(&format!("{}%", (doc.scroll_fraction() * 100.0).round() as i32));
            };
            adj.connect_value_changed(show.clone());
            adj.connect_changed(show);
        }
        restore_when_ready(&doc, position.or(saved.reading_position()));

        // --- links --------------------------------------------------------

        {
            let doc_weak = Rc::downgrade(&doc);
            let parent = window.clone();
            let app = app.clone();
            let path = path.to_path_buf();
            doc.set_on_follow_link(move |link| match reader::link_target(link, Some(&path)) {
                LinkTarget::Anchor(anchor) => {
                    if let Some(doc) = doc_weak.upgrade() {
                        scroll_to_anchor(&doc, &anchor);
                    }
                }
                LinkTarget::External(url) => {
                    gtk4::UriLauncher::new(&url).launch(Some(&parent), gtk4::gio::Cancellable::NONE, |result| {
                        if let Err(e) = result {
                            eprintln!("tvmv: opening link: {e}");
                        }
                    });
                }
                LinkTarget::Document(target) => {
                    crate::app::open_window(&app, &target);
                }
                LinkTarget::Blocked => WidgetExt::display(&parent).beep(),
            });
        }

        // --- actions ------------------------------------------------------

        let editing: Rc<dyn Fn(bool)> = Rc::new({
            let doc = Rc::clone(&doc);
            let toggle_editor = toggle_editor.clone();
            let update_title = update_title.clone();
            move |on: bool| {
                // A large document becomes editable once its whole parse has
                // landed; until then the request waits.
                if !doc.is_loaded() {
                    let doc = Rc::downgrade(&doc);
                    let toggle_editor = toggle_editor.clone();
                    glib::timeout_add_local(Duration::from_millis(50), move || {
                        let Some(doc) = doc.upgrade() else { return glib::ControlFlow::Break };
                        if !doc.is_loaded() {
                            return glib::ControlFlow::Continue;
                        }
                        toggle_editor.set_active(on);
                        glib::ControlFlow::Break
                    });
                    return;
                }
                doc.set_editable(on);
                if on {
                    doc.view.grab_focus();
                }
                if toggle_editor.is_active() != on {
                    toggle_editor.set_active(on);
                }
                update_title();
            }
        });
        {
            let editing = Rc::clone(&editing);
            let doc = Rc::clone(&doc);
            toggle_editor.connect_toggled(move |b| {
                if doc.is_editable() != b.is_active() {
                    editing(b.is_active());
                }
            });
        }
        {
            let sidebar = outline.widget.clone();
            toggle_outline.connect_clicked(move |_| sidebar.set_visible(!sidebar.is_visible()));
        }
        {
            let find = Rc::clone(&find);
            open_find.connect_clicked(move |_| find.open());
        }
        {
            let doc = Rc::clone(&doc);
            let state = Rc::clone(&state);
            let go_bookmark = go_bookmark.clone();
            let path = path.to_path_buf();
            save_bookmark.connect_clicked(move |_| {
                let mut s = state.get();
                s.bookmark_offset = Some(doc.top_offset());
                s.bookmark = None;
                state.set(s);
                go_bookmark.set_sensitive(true);
                reading::save(&path, ReadingState { ..s });
            });
        }
        {
            let doc = Rc::clone(&doc);
            let state = Rc::clone(&state);
            go_bookmark.connect_clicked(move |_| match state.get().bookmark_position() {
                Some(Position::Offset(o)) => doc.scroll_to_offset(o),
                Some(Position::Fraction(f)) => doc.scroll_to_fraction(f),
                None => {}
            });
        }
        // Right-click "Go to bookmark" to clear it, as on macOS. The button is
        // insensitive without a bookmark, so the menu only appears with one.
        {
            let clear = gtk4::gio::SimpleAction::new("clear-bookmark", None);
            let state = Rc::clone(&state);
            let button = go_bookmark.clone();
            let path = path.to_path_buf();
            clear.connect_activate(move |_, _| {
                let mut s = state.get();
                s.clear_bookmark();
                state.set(s);
                button.set_sensitive(false);
                reading::save(&path, s);
            });
            window.add_action(&clear);

            let menu = gtk4::gio::Menu::new();
            menu.append(Some("Clear Bookmark"), Some("win.clear-bookmark"));
            let popover = gtk4::PopoverMenu::from_model(Some(&menu));
            popover.set_parent(&go_bookmark);
            let gesture = gtk4::GestureClick::new();
            gesture.set_button(gtk4::gdk::BUTTON_SECONDARY);
            {
                let popover = popover.clone();
                gesture.connect_pressed(move |_, _, _, _| popover.popup());
            }
            go_bookmark.add_controller(gesture);
            go_bookmark.connect_destroy(move |_| popover.unparent());
        }

        let print = {
            let doc = Rc::clone(&doc);
            let window = window.clone();
            let path = path.to_path_buf();
            move |pdf: bool| {
                let output = if pdf {
                    crate::print::Output::SaveAs(window.clone(), crate::print::pdf_name_for(&path))
                } else {
                    crate::print::Output::Dialog(window.clone())
                };
                let settings = crate::app::shared_settings();
                crate::print::print_markdown(&doc.text(), path.parent().map(PathBuf::from), &settings.borrow(), output);
            }
        };
        {
            let print = print.clone();
            print_button.connect_clicked(move |_| print(false));
        }
        let show_settings = {
            let window = window.clone();
            move || {
                crate::settings_ui::present(
                    &window,
                    crate::app::shared_settings(),
                    Rc::new(crate::app::apply_settings_to_all),
                );
            }
        };
        {
            let show = show_settings.clone();
            open_settings.connect_clicked(move |_| show());
        }
        let save = {
            let doc = Rc::clone(&doc);
            let document = Rc::clone(&document);
            let window = window.clone();
            let update_title = update_title.clone();
            move || {
                document.borrow_mut().set_text(doc.text());
                if save_document(&document, &window) {
                    update_title();
                }
            }
        };

        let keys = gtk4::EventControllerKey::new();
        {
            let find = Rc::clone(&find);
            let doc = Rc::clone(&doc);
            let search = Rc::clone(&search);
            let sidebar = outline.widget.clone();
            let editing = Rc::clone(&editing);
            keys.connect_key_pressed(move |_, key, _, modifier| {
                use gtk4::gdk::Key;
                let ctrl = modifier.contains(gtk4::gdk::ModifierType::CONTROL_MASK);
                let shift = modifier.contains(gtk4::gdk::ModifierType::SHIFT_MASK);
                match key {
                    Key::f if ctrl => find.open(),
                    // Ctrl+P prints; Ctrl+Shift+P goes straight to a PDF.
                    Key::P | Key::p if ctrl && shift => print(true),
                    Key::p if ctrl => print(false),
                    // Ctrl+, is the GNOME convention for preferences.
                    Key::comma if ctrl => show_settings(),
                    Key::e if ctrl => editing(!doc.is_editable()),
                    Key::s if ctrl => save(),
                    Key::F9 => sidebar.set_visible(!sidebar.is_visible()),
                    Key::Escape if find.is_open() => {
                        find.close();
                        run_find(&doc, &search, &find, FindAction::Clear, "");
                    }
                    _ => return glib::Propagation::Proceed,
                }
                glib::Propagation::Stop
            });
        }
        window.add_controller(keys);

        // --- live reload --------------------------------------------------
        //
        // The watcher runs on its own thread; changes reach the main loop
        // through a channel.
        let (change_tx, change_rx) = async_channel::unbounded::<()>();
        let mut watcher = crate::watcher::FileWatcher::new(path, crate::watcher::DEFAULT_DEBOUNCE, move || {
            let _ = change_tx.send_blocking(());
        });
        watcher.start();
        {
            let document = Rc::clone(&document);
            let doc = Rc::clone(&doc);
            let window = window.clone();
            let update_title = update_title.clone();
            glib::spawn_future_local(async move {
                while change_rx.recv().await.is_ok() {
                    document.borrow_mut().set_text(doc.text());
                    on_file_changed(&document, &doc, &window, &update_title);
                }
            });
        }

        // Close guard: keep the place, and never lose unsaved edits.
        {
            let document = Rc::clone(&document);
            let doc = Rc::clone(&doc);
            let path = path.to_path_buf();
            let state = Rc::clone(&state);
            window.connect_close_request(move |window| {
                if doc.is_loaded() {
                    reading::save(&path, ReadingState {
                        position: doc.scroll_fraction(),
                        offset: Some(doc.top_offset()),
                        ..state.get()
                    });
                }
                document.borrow_mut().set_text(doc.text());
                if !document.borrow().is_dirty() {
                    return glib::Propagation::Proceed;
                }
                confirm_discard(window, &document);
                glib::Propagation::Stop
            });
        }

        let this = Self { window, doc, outline_widget: outline.widget.clone(), editing, tint, _watcher: watcher };
        if editable {
            this.start_editing();
        }
        this
    }

    /// Make the document editable (idempotent, unlike Ctrl+E).
    pub fn start_editing(&self) {
        (self.editing)(true);
    }

    /// Push changed settings into this window, live.
    pub fn apply_settings(&self, settings: &Settings) {
        self.doc.set_theme(theme_for(settings));
        (self.tint)();
        // `show_outline` is the default for new windows; toggling it in
        // settings shows at once in the windows already open.
        self.outline_widget.set_visible(settings.show_outline);
    }
}

fn scroll_to_anchor(doc: &DocumentView, anchor: &str) {
    if let Some(heading) = reader::heading_for_anchor(&doc.headings(), anchor) {
        doc.scroll_to_offset(heading.range.start);
    }
}

/// Restore `position` once it can be reached. Where an offset lands depends
/// on line wrapping, so it waits for the whole text and the view's width;
/// and GTK can scroll only as far as it has laid lines out, which it does
/// top-down in the background after styling. The target line's top stops
/// moving once every line above it is laid out: then scroll, once. Scrolling
/// by hand first cancels it.
fn restore_when_ready(doc: &Rc<DocumentView>, position: Option<Position>) {
    let Some(position) = position else { return };
    let doc = Rc::downgrade(doc);
    let (start, last_y, steady) = (std::cell::OnceCell::new(), Cell::new(-1), Cell::new(0));
    let began = std::time::Instant::now();
    glib::timeout_add_local(Duration::from_millis(50), move || {
        let Some(doc) = doc.upgrade() else { return glib::ControlFlow::Break };
        let Some(adj) = doc.view.vadjustment() else { return glib::ControlFlow::Break };
        if !doc.is_loaded() || doc.view.width() == 0 {
            return glib::ControlFlow::Continue;
        }
        let value = *start.get_or_init(|| adj.value());
        if (adj.value() - value).abs() > 2.0 {
            return glib::ControlFlow::Break;
        }
        let offset = match position {
            Position::Offset(o) => o,
            // A fraction of a height still growing means nothing until the
            // layout is complete; then it is an offset like any other.
            Position::Fraction(_) => doc.text().len(),
        };
        let target = {
            let model = doc.model.borrow();
            doc.buffer.iter_at_offset(model.source.to_buffer(offset.min(model.source.text().len())))
        };
        let (y, _) = doc.view.line_yrange(&target);
        steady.set(if y == last_y.replace(y) { steady.get() + 1 } else { 0 });
        if doc.is_styling() || steady.get() < 2 {
            return glib::ControlFlow::Continue;
        }
        match position {
            Position::Offset(o) => doc.scroll_to_offset(o),
            Position::Fraction(f) => doc.scroll_to_fraction(f),
        }
        if std::env::var_os("TVMV_TRACE_RESTORE").is_some() {
            eprintln!("tvmv: restored {position:?} after {:?}", began.elapsed());
        }
        glib::ControlFlow::Break
    });
}

fn run_find(doc: &DocumentView, search: &RefCell<Search>, find: &Find, action: FindAction, query: &str) {
    if action == FindAction::Clear || query.is_empty() {
        *search.borrow_mut() = Search::default();
        doc.set_find(Vec::new(), None);
        find.set_matches(0, 0);
        return;
    }
    let mut s = search.borrow_mut();
    match action {
        FindAction::Search => {
            s.matches = reader::find_matches(&doc.text(), query);
            // The first match from the top of the screen down.
            let top = doc.top_offset();
            s.current = (!s.matches.is_empty()).then(|| s.matches.partition_point(|m| m.start < top) % s.matches.len());
        }
        FindAction::Next | FindAction::Previous if !s.matches.is_empty() => {
            let n = s.matches.len();
            s.current = Some(match (s.current, action) {
                (Some(i), FindAction::Next) => (i + 1) % n,
                (Some(i), _) => (i + n - 1) % n,
                (None, _) => 0,
            });
        }
        _ => {}
    }
    doc.set_find(s.matches.clone(), s.current);
    if let Some(range) = s.current.map(|i| s.matches[i].clone()) {
        doc.show_match(range);
    }
    find.set_matches(s.matches.len() as i64, s.current.map_or(0, |i| i as i64 + 1));
}

/// Search again after an edit, keeping the current match's place without
/// moving the caret or the view.
fn refresh_find(doc: &DocumentView, search: &RefCell<Search>, find: &Find) {
    let mut s = search.borrow_mut();
    let at = s.current.and_then(|i| s.matches.get(i)).map(|m| m.start);
    s.matches = reader::find_matches(&doc.text(), &find.query());
    s.current = match at {
        Some(at) if !s.matches.is_empty() => Some(s.matches.partition_point(|m| m.start < at).min(s.matches.len() - 1)),
        _ => None,
    };
    doc.set_find(s.matches.clone(), s.current);
    find.set_matches(s.matches.len() as i64, s.current.map_or(0, |i| i as i64 + 1));
}

/// The document changed on disk. Three outcomes, by how much they can cost
/// the user:
///
/// 1. **It was us.** A save fires the watcher like any other write; content
///    equal to the last save is ours.
/// 2. **No unsaved edits:** adopt it, keeping the place. That is live reload.
/// 3. **Unsaved edits:** never silently discard them. Ask.
fn on_file_changed(
    document: &Rc<RefCell<Document>>,
    doc: &Rc<DocumentView>,
    window: &ApplicationWindow,
    update_title: &(impl Fn() + Clone + 'static),
) {
    // Mid-write, or deleted and about to be recreated: the watcher will fire
    // again when it settles.
    let Ok(disk) = document.borrow().read_from_disk() else { return };
    if disk == document.borrow().last_saved() {
        return;
    }
    if document.borrow().is_dirty() {
        confirm_external_change(window, document, doc, update_title);
        return;
    }
    if document.borrow_mut().reload().is_ok() {
        adopt_reloaded(document, doc, update_title);
    }
}

fn adopt_reloaded(document: &Rc<RefCell<Document>>, doc: &Rc<DocumentView>, update_title: &impl Fn()) {
    let top = doc.top_offset();
    let editable = doc.is_editable();
    doc.load(document.borrow().text().to_string());
    doc.set_editable(editable);
    restore_when_ready(doc, Some(Position::Offset(top)));
    update_title();
}

fn confirm_external_change(
    window: &ApplicationWindow,
    document: &Rc<RefCell<Document>>,
    doc: &Rc<DocumentView>,
    update_title: &(impl Fn() + Clone + 'static),
) {
    let name = document
        .borrow()
        .path()
        .file_name()
        .map_or_else(|| "This document".to_string(), |n| n.to_string_lossy().into_owned());
    let dialog = gtk4::AlertDialog::builder()
        .message(format!("{name} changed on disk"))
        .detail("You have unsaved edits. Reloading discards them.")
        .buttons(["Keep my edits", "Reload from disk"])
        .cancel_button(0)
        .default_button(0)
        .modal(true)
        .build();
    let document = Rc::clone(document);
    let doc = Rc::clone(doc);
    let update_title = update_title.clone();
    dialog.choose(Some(window), gtk4::gio::Cancellable::NONE, move |answer| {
        if answer == Ok(1) && document.borrow_mut().reload().is_ok() {
            adopt_reloaded(&document, &doc, &update_title);
        }
    });
}

/// Save, showing why when it fails. Whether it saved.
fn save_document(document: &Rc<RefCell<Document>>, window: &ApplicationWindow) -> bool {
    let Err(e) = document.borrow_mut().save() else { return true };
    let path = document.borrow().path().display().to_string();
    eprintln!("tvmv: saving {path}: {e}");
    gtk4::AlertDialog::builder()
        .message("Could not save")
        .detail(format!("{path}: {e}"))
        .modal(true)
        .build()
        .show(Some(window));
    false
}

/// Ask before dropping unsaved edits, then act on the answer.
fn confirm_discard(window: &ApplicationWindow, document: &Rc<RefCell<Document>>) {
    let name = document
        .borrow()
        .path()
        .file_name()
        .map_or_else(|| "this document".to_string(), |n| n.to_string_lossy().into_owned());
    let dialog = gtk4::AlertDialog::builder()
        .message(format!("Save changes to {name}?"))
        .detail("Your changes will be lost if you don't save them.")
        .buttons(["Cancel", "Discard", "Save"])
        .cancel_button(0)
        .default_button(2)
        .modal(true)
        .build();
    let document = Rc::clone(document);
    let window = window.clone();
    dialog.choose(Some(&window.clone()), gtk4::gio::Cancellable::NONE, move |answer| match answer {
        Ok(1) => {
            // Discard: the guard checks dirtiness, so clear it first.
            document.borrow_mut().mark_clean();
            window.close();
        }
        // A failed save keeps the window open: closing anyway would lose
        // the edits.
        Ok(2) if save_document(&document, &window) => window.close(),
        _ => {}
    });
}
