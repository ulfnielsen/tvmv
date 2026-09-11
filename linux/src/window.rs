//! A document window: outline sidebar, find bar, and the preview web view.
//!
//! No titlebar widget is set, so the window manager draws server-side
//! decorations — what KDE and tiling-WM users expect, and what libadwaita would
//! have made impossible. Every icon is referenced by freedesktop name so it
//! follows the installed theme; none are shipped.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{
    Application, ApplicationWindow, Box as GtkBox, Button, CssProvider, Orientation, Paned,
};
use webkit6::prelude::*;

use crate::chrome;
use crate::document::Document;
use crate::editor::{Editor, EditorMessage};
use crate::find::{Find, FindAction};
use crate::outline::Outline;
use crate::preview::{Preview, PreviewMessage};
use crate::render::render_html;
use crate::settings::Settings;

pub struct DocumentWindow {
    pub window: ApplicationWindow,
    pub preview: Rc<Preview>,
    editor: Rc<Editor>,
    outline_widget: gtk4::ScrolledWindow,
    /// Held so live reload keeps working — dropping it stops the watch.
    _watcher: crate::watcher::FileWatcher,
}

/// Preview re-render debounce after an edit, scaled to document size.
///
/// A settled edit costs a full parse plus DOM replacement, so large documents
/// wait longer before paying it while small ones keep the snappy cadence.
/// Matches `ViewerModel.renderDebounceDelay`.
fn render_debounce(text: &str) -> std::time::Duration {
    let bytes = text.len();
    let ms = if bytes > 4_000_000 {
        1000
    } else if bytes > 1_000_000 {
        600
    } else {
        250
    };
    std::time::Duration::from_millis(ms)
}

/// Fired when the page reports it has finished rendering, including the lazy
/// KaTeX / Mermaid / highlight.js passes.
pub type OnRenderComplete = Box<dyn Fn(&Preview)>;

/// The user's stylesheet, or empty for the built-in theme.
fn read_user_css(settings: &Settings) -> String {
    let Some(path) = settings.custom_css_path() else {
        return String::new();
    };
    std::fs::read_to_string(&path).unwrap_or_else(|e| {
        eprintln!("tvmv: {}: {e}", path.display());
        String::new()
    })
}

impl DocumentWindow {
    pub fn new(
        app: &Application,
        web_dir: &Path,
        path: &Path,
        settings: &Settings,
        on_render_complete: Option<OnRenderComplete>,
    ) -> Self {
        Self::build(app, web_dir, path, settings, on_render_complete, false)
    }

    /// A chromeless preview: no toolbar, no sidebar, Escape closes.
    ///
    /// The point of a previewer is that it is instant, so this deliberately
    /// reuses the running instance (and its warm WebProcess) rather than
    /// starting a second one.
    pub fn peek(
        app: &Application,
        web_dir: &Path,
        path: &Path,
        settings: &Settings,
    ) -> Self {
        Self::build(app, web_dir, path, settings, None, true)
    }

    fn build(
        app: &Application,
        web_dir: &Path,
        path: &Path,
        settings: &Settings,
        on_render_complete: Option<OnRenderComplete>,
        peek: bool,
    ) -> Self {
        let title = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "tvmv".to_string());

        // TVMV_WINDOW_SIZE=WxH is a diagnostic override for performance testing.
        let (width, height) = std::env::var("TVMV_WINDOW_SIZE")
            .ok()
            .and_then(|spec| {
                let (w, h) = spec.split_once('x')?;
                Some((w.parse().ok()?, h.parse().ok()?))
            })
            .unwrap_or((900, 1000));

        let window = ApplicationWindow::builder()
            .application(app)
            .title(&title)
            .default_width(width)
            .default_height(height)
            .build();

        // --- widgets ------------------------------------------------------

        // The document is the single source of truth for text and dirtiness;
        // the editor page is authoritative for *edits*, and resyncs from it
        // whenever a patch payload does not apply cleanly.
        let document = match Document::load(path) {
            Ok(doc) => Rc::new(RefCell::new(doc)),
            Err(e) => {
                eprintln!("tvmv: {}: {e}", path.display());
                Rc::new(RefCell::new(Document::empty(path)))
            }
        };
        let editor_slot: Rc<RefCell<Option<Rc<Editor>>>> = Rc::new(RefCell::new(None));
        // Bumped on every edit; a pending re-render whose generation is stale
        // has been superseded and does nothing.
        let render_generation = Rc::new(std::cell::Cell::new(0u64));

        let done = Rc::new(RefCell::new(on_render_complete));
        let preview_slot: Rc<RefCell<Option<Rc<Preview>>>> = Rc::new(RefCell::new(None));
        let outline_slot: Rc<RefCell<Option<Rc<Outline>>>> = Rc::new(RefCell::new(None));
        let find_slot: Rc<RefCell<Option<Rc<Find>>>> = Rc::new(RefCell::new(None));
        let tint_provider = CssProvider::new();
        // Each window tints only itself: GTK4 providers are display-wide, so the
        // selectors are scoped by a per-window class.
        let scope = chrome::scope_class(next_window_serial());
        window.add_css_class(&scope);

        let outline = Rc::new(Outline::new({
            let slot = Rc::clone(&preview_slot);
            move |anchor| {
                if let Some(preview) = slot.borrow().as_ref() {
                    preview.scroll_to_anchor(anchor);
                }
            }
        }));
        *outline_slot.borrow_mut() = Some(Rc::clone(&outline));

        let find = Rc::new(Find::new({
            let preview_slot = Rc::clone(&preview_slot);
            let find_slot = Rc::clone(&find_slot);
            move |action, query| {
                let Some(preview) = preview_slot.borrow().clone() else { return };
                let Some(find) = find_slot.borrow().clone() else { return };
                match action {
                    FindAction::Clear => {
                        preview.clear_find();
                        find.set_matches(0, 0);
                    }
                    FindAction::Search | FindAction::Next | FindAction::Previous
                        if query.is_empty() =>
                    {
                        preview.clear_find();
                        find.set_matches(0, 0);
                    }
                    _ => {
                        let script = match action {
                            FindAction::Search => {
                                format!("window.tvmv.find({});", crate::js::literal(query))
                            }
                            FindAction::Next => "window.tvmv.findNext(1);".to_string(),
                            FindAction::Previous => "window.tvmv.findNext(-1);".to_string(),
                            FindAction::Clear => unreachable!(),
                        };
                        preview.eval_json(&script, move |value| {
                            let count =
                                value.as_ref().and_then(|v| v.get("count")?.as_i64()).unwrap_or(0);
                            let index =
                                value.as_ref().and_then(|v| v.get("index")?.as_i64()).unwrap_or(0);
                            find.set_matches(count, index);
                        });
                    }
                }
            }
        }));
        *find_slot.borrow_mut() = Some(Rc::clone(&find));

        // --- preview ------------------------------------------------------

        let preview = Rc::new(Preview::new(web_dir, {
            let outline_slot = Rc::clone(&outline_slot);
            let preview_slot = Rc::clone(&preview_slot);
            let done = Rc::clone(&done);
            let scope = scope.clone();
            let tint_provider = tint_provider.clone();
            move |message| match message {
                PreviewMessage::Outline(items) => {
                    if let Some(outline) = outline_slot.borrow().as_ref() {
                        outline.set_items(&items);
                    }
                }
                PreviewMessage::RenderComplete => {
                    // Re-tint from the *rendered* page, so a custom stylesheet
                    // colours the window too. Until this fires the window wears
                    // the built-in theme's paper (see `theme::paper`).
                    if let Some(preview) = preview_slot.borrow().clone() {
                        let scope = scope.clone();
                        let provider = tint_provider.clone();
                        preview.eval_json(
                            "getComputedStyle(document.body).backgroundColor",
                            move |value| {
                                let Some(css) = value.as_ref().and_then(|v| v.as_str()) else {
                                    return;
                                };
                                if let Some(tint) = chrome::tint_from_page_background(css) {
                                    chrome::apply_tint(&scope, tint, &provider);
                                }
                            },
                        );
                    }
                    if let (Some(preview), Some(callback)) =
                        (preview_slot.borrow().as_ref(), done.borrow().as_ref())
                    {
                        callback(preview);
                    }
                }
                PreviewMessage::Error(msg) => eprintln!("tvmv: preview: {msg}"),
                // Editor sync lands in Task 10.
                PreviewMessage::SourceClick { .. } => {}
            }
        }));
        *preview_slot.borrow_mut() = Some(Rc::clone(&preview));

        // --- editor -------------------------------------------------------

        let editor = Rc::new(Editor::new({
            let document = Rc::clone(&document);
            let editor_slot = Rc::clone(&editor_slot);
            let preview_slot = Rc::clone(&preview_slot);
            let window = window.clone();
            let generation = Rc::clone(&render_generation);
            let editor_style = settings.editor_style_json(system_prefers_dark());
            move |message| match message {
                EditorMessage::Ready => {
                    let Some(editor) = editor_slot.borrow().clone() else { return };
                    editor.apply_style(&editor_style);
                    // resetHistory: this is a fresh document, not a reload.
                    editor.set_text(document.borrow().text(), true);
                    editor.focus();
                }
                EditorMessage::TextPatch { patches, length } => {
                    let applied = document.borrow_mut().apply_patches(&patches, length);
                    if applied {
                        window.set_title(Some(&document.borrow().title()));
                        schedule_render(&generation, &document, &preview_slot);
                    } else if let Some(editor) = editor_slot.borrow().clone() {
                        // Incoherent payload: the editor is authoritative, so
                        // pull the whole document rather than guess.
                        let document = Rc::clone(&document);
                        let preview_slot = Rc::clone(&preview_slot);
                        let generation = Rc::clone(&generation);
                        let window = window.clone();
                        editor.get_text(move |text| {
                            let Some(text) = text else { return };
                            document.borrow_mut().set_text(text);
                            window.set_title(Some(&document.borrow().title()));
                            schedule_render(&generation, &document, &preview_slot);
                        });
                    }
                }
                EditorMessage::Scrolled { top_line } => {
                    if let Some(preview) = preview_slot.borrow().as_ref() {
                        preview.scroll_to_source_line(top_line);
                    }
                }
                EditorMessage::CursorMoved { line, .. } => {
                    if let Some(preview) = preview_slot.borrow().as_ref() {
                        preview.reveal_source_line(line);
                    }
                }
                EditorMessage::Error(msg) => eprintln!("tvmv: editor: {msg}"),
            }
        }));
        *editor_slot.borrow_mut() = Some(Rc::clone(&editor));
        editor.web_view.set_visible(false);

        // --- layout -------------------------------------------------------

        let toggle_outline = Button::from_icon_name("sidebar-show-symbolic");
        toggle_outline.set_tooltip_text(Some("Toggle outline (F9)"));
        toggle_outline.add_css_class("flat");
        let open_find = Button::from_icon_name("edit-find-symbolic");
        open_find.set_tooltip_text(Some("Find (Ctrl+F)"));
        open_find.add_css_class("flat");

        let toolbar = GtkBox::new(Orientation::Horizontal, 2);
        toolbar.add_css_class("tvmv-toolbar");
        toolbar.set_margin_start(4);
        toolbar.set_margin_end(4);
        toolbar.set_margin_top(2);
        toolbar.set_margin_bottom(2);
        let toggle_editor = Button::from_icon_name("document-edit-symbolic");
        toggle_editor.set_tooltip_text(Some("Toggle editor (Ctrl+E)"));
        toggle_editor.add_css_class("flat");

        let print_button = Button::from_icon_name("document-print-symbolic");
        print_button.set_tooltip_text(Some("Print or save as PDF (Ctrl+P)"));
        print_button.add_css_class("flat");

        let open_settings = Button::from_icon_name("preferences-system-symbolic");
        open_settings.set_tooltip_text(Some("Settings (Ctrl+,)"));
        open_settings.add_css_class("flat");

        toolbar.append(&toggle_outline);
        toolbar.append(&open_find);
        toolbar.append(&toggle_editor);
        toolbar.append(&print_button);
        toolbar.append(&open_settings);

        let editor_split = Paned::new(Orientation::Horizontal);
        editor_split.set_start_child(Some(&editor.web_view));
        editor_split.set_end_child(Some(&preview.web_view));
        editor_split.set_position(if settings.editor_pane_width > 0.0 {
            settings.editor_pane_width as i32
        } else {
            420
        });

        let split = Paned::new(Orientation::Horizontal);
        split.set_start_child(Some(&outline.widget));
        split.set_end_child(Some(&editor_split));
        split.set_position(240);
        split.set_resize_start_child(false);
        split.set_shrink_start_child(false);
        split.set_vexpand(true);
        outline.widget.set_visible(settings.show_outline);

        let content = GtkBox::new(Orientation::Vertical, 0);
        if !peek {
            content.append(&toolbar);
            content.append(&find.widget);
        }
        content.append(&split);
        window.set_child(Some(&content));

        if peek {
            outline.widget.set_visible(false);
            // Centred and a little inset, like a previewer rather than a window
            // you are meant to keep.
            window.set_default_size((width as f64 * 0.85) as i32, (height as f64 * 0.85) as i32);
        }

        // Tint the window before the page exists, so there is no cold flash.
        let paper = crate::theme::paper(web_dir, system_prefers_dark());
        preview.set_background(paper);
        let initial = chrome::Rgba { red: paper.0, green: paper.1, blue: paper.2, alpha: 1.0 };
        chrome::apply_tint(&scope, initial, &tint_provider);
        if let Some(display) = gtk4::gdk::Display::default() {
            gtk4::style_context_add_provider_for_display(
                &display,
                &tint_provider,
                gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
        }

        // --- actions and shortcuts ----------------------------------------

        {
            let sidebar = outline.widget.clone();
            toggle_outline.connect_clicked(move |_| sidebar.set_visible(!sidebar.is_visible()));
        }
        {
            let find = Rc::clone(&find);
            open_find.connect_clicked(move |_| find.open());
        }

        // Toggling the pane on loads editor.html the first time — CodeMirror is
        // 1.5 MB, and a reader who never edits should never pay for it.
        let editor_loaded = Rc::new(std::cell::Cell::new(false));
        let toggle_editing = {
            let editor = Rc::clone(&editor);
            let loaded = Rc::clone(&editor_loaded);
            let document = Rc::clone(&document);
            move || {
                let showing = !editor.web_view.is_visible();
                editor.web_view.set_visible(showing);
                if !showing {
                    return;
                }
                if !loaded.replace(true) {
                    editor.load();
                } else {
                    // Already loaded: re-seed without dropping undo history.
                    editor.set_text(document.borrow().text(), false);
                    editor.focus();
                }
            }
        };
        {
            let toggle = toggle_editing.clone();
            toggle_editor.connect_clicked(move |_| toggle());
        }

        let do_print = {
            let preview = Rc::clone(&preview);
            let window = window.clone();
            move || crate::print::print(&preview.web_view, &window)
        };
        {
            let print = do_print.clone();
            print_button.connect_clicked(move |_| print());
        }

        let save_pdf = {
            let preview = Rc::clone(&preview);
            let window = window.clone();
            let path = path.to_path_buf();
            move || {
                crate::print::save_as_pdf(
                    &preview.web_view,
                    &window,
                    &crate::print::pdf_name_for(&path),
                )
            }
        };

        let show_settings = {
            let window = window.clone();
            move || {
                crate::settings_ui::present(
                    &window,
                    crate::app::shared_settings(),
                    std::rc::Rc::new(crate::app::apply_settings_to_all),
                );
            }
        };
        {
            let show = show_settings.clone();
            open_settings.connect_clicked(move |_| show());
        }

        let keys = gtk4::EventControllerKey::new();
        {
            let find = Rc::clone(&find);
            let sidebar = outline.widget.clone();
            let preview_for_keys = Rc::clone(&preview);
            let toggle_editing_for_keys = toggle_editing.clone();
            let show_settings_for_keys = show_settings.clone();
            let print_for_keys = do_print.clone();
            let peek_window = window.clone();
            let save_pdf_for_keys = save_pdf.clone();
            let save_doc = Rc::clone(&document);
            let save_window = window.clone();
            keys.connect_key_pressed(move |_, key, _, modifier| {
                use gtk4::gdk::Key;
                let ctrl = modifier.contains(gtk4::gdk::ModifierType::CONTROL_MASK);
                let shift = modifier.contains(gtk4::gdk::ModifierType::SHIFT_MASK);
                match key {
                    Key::f if ctrl => {
                        find.open();
                        gtk4::glib::Propagation::Stop
                    }
                    // Ctrl+, is the GNOME convention for preferences.
                    // Ctrl+P prints; Ctrl+Shift+P goes straight to a PDF.
                    Key::P | Key::p if ctrl && shift => {
                        save_pdf_for_keys();
                        gtk4::glib::Propagation::Stop
                    }
                    Key::p if ctrl => {
                        print_for_keys();
                        gtk4::glib::Propagation::Stop
                    }
                    Key::comma if ctrl => {
                        show_settings_for_keys();
                        gtk4::glib::Propagation::Stop
                    }
                    Key::e if ctrl => {
                        toggle_editing_for_keys();
                        gtk4::glib::Propagation::Stop
                    }
                    Key::s if ctrl => {
                        save_document(&save_doc, &save_window);
                        gtk4::glib::Propagation::Stop
                    }
                    Key::F9 => {
                        sidebar.set_visible(!sidebar.is_visible());
                        gtk4::glib::Propagation::Stop
                    }
                    // In a peek window Escape closes outright — that is the
                    // whole interaction.
                    Key::Escape if peek => {
                        peek_window.close();
                        gtk4::glib::Propagation::Stop
                    }
                    Key::Escape if find.is_open() => {
                        find.close();
                        preview_for_keys.clear_find();
                        find.set_matches(0, 0);
                        gtk4::glib::Propagation::Stop
                    }
                    _ => gtk4::glib::Propagation::Proceed,
                }
            });
        }
        window.add_controller(keys);

        // --- content ------------------------------------------------------

        preview.set_document_directory(path.parent().map(PathBuf::from));

        let load_preview = Rc::clone(&preview);
        let load_document = Rc::clone(&document);
        let style_json = settings.style_json(system_prefers_dark());
        let load_user_css = read_user_css(settings);
        preview.web_view.connect_load_changed(move |_, event| {
            if event != webkit6::LoadEvent::Finished {
                return;
            }
            // The template page and boot.js are loaded; `window.tvmv` is callable.
            load_preview.apply_style(&style_json);
            // The user stylesheet has to be injected on every page load too, not
            // only when it changes in Settings — otherwise a configured theme is
            // ignored until the user opens the dialog.
            load_preview.apply_user_css(&load_user_css);

            let html = render_html(load_document.borrow().text(), true);
            load_preview.render(&html, &format!("{}://doc/", crate::assets::SCHEME));
        });

        // --- live reload --------------------------------------------------
        //
        // The watcher runs on its own thread, so changes are delivered to the
        // GTK main loop through a channel rather than touching widgets from
        // off-thread.
        let (change_tx, change_rx) = async_channel::unbounded::<()>();
        let mut watcher = crate::watcher::FileWatcher::new(
            path,
            crate::watcher::DEFAULT_DEBOUNCE,
            move || {
                let _ = change_tx.send_blocking(());
            },
        );
        watcher.start();

        {
            let document = Rc::clone(&document);
            let preview_slot = Rc::clone(&preview_slot);
            let editor_slot = Rc::clone(&editor_slot);
            let generation = Rc::clone(&render_generation);
            let window = window.clone();
            gtk4::glib::spawn_future_local(async move {
                while change_rx.recv().await.is_ok() {
                    on_file_changed(&document, &preview_slot, &editor_slot, &generation, &window);
                }
            });
        }

        // Close guard: unsaved edits must not disappear with the window.
        {
            let document = Rc::clone(&document);
            window.connect_close_request(move |window| {
                if !document.borrow().is_dirty() {
                    return gtk4::glib::Propagation::Proceed;
                }
                confirm_discard(window, &document);
                gtk4::glib::Propagation::Stop
            });
        }

        preview.load_template();

        Self {
            window,
            preview,
            editor: Rc::clone(&editor),
            outline_widget: outline.widget.clone(),
            _watcher: watcher,
        }
    }
}

impl DocumentWindow {
    /// Push changed settings into this window, live.
    ///
    /// Typography and theme go through the shared `applyStyle`; the custom
    /// stylesheet through `applyUserCSS`, which is appended after the built-in
    /// theme so it overrides it. Reading the file here rather than in the
    /// settings window keeps the "no stylesheet" case a single empty string.
    pub fn apply_settings(&self, settings: &Settings) {
        let dark = system_prefers_dark();
        self.preview.apply_style(&settings.style_json(dark));
        self.editor.apply_style(&settings.editor_style_json(dark));

        self.preview.apply_user_css(&read_user_css(settings));

        // `show_outline` is the default for new windows; toggling it in settings
        // should still be visible immediately in the ones already open.
        self.outline_widget.set_visible(settings.show_outline);
    }
}

/// The document changed on disk.
///
/// Three outcomes, in order of how much they can cost the user:
///
/// 1. **It was us.** A save fires the watcher like any other write, and the
///    watcher cannot tell whose write it was. Comparing content against the
///    last-saved text is reliable where a timing window is not.
/// 2. **Clean document** — adopt it silently. That is live reload, and it is
///    the whole point of watching.
/// 3. **Unsaved edits** — never silently discard them. Ask.
fn on_file_changed(
    document: &Rc<RefCell<Document>>,
    preview_slot: &Rc<RefCell<Option<Rc<Preview>>>>,
    editor_slot: &Rc<RefCell<Option<Rc<Editor>>>>,
    generation: &Rc<std::cell::Cell<u64>>,
    window: &ApplicationWindow,
) {
    let disk = match document.borrow().read_from_disk() {
        Ok(text) => text,
        // Mid-write, or deleted and about to be recreated: the watcher will
        // fire again when it settles.
        Err(_) => return,
    };

    if disk == document.borrow().last_saved() {
        return; // our own save
    }

    if document.borrow().is_dirty() {
        confirm_external_change(window, document, preview_slot, editor_slot, generation);
        return;
    }

    if document.borrow_mut().reload().is_err() {
        return;
    }
    adopt_reloaded(document, preview_slot, editor_slot, generation, window);
}

/// Push freshly-loaded text into the preview, the editor, and the title.
fn adopt_reloaded(
    document: &Rc<RefCell<Document>>,
    preview_slot: &Rc<RefCell<Option<Rc<Preview>>>>,
    editor_slot: &Rc<RefCell<Option<Rc<Editor>>>>,
    generation: &Rc<std::cell::Cell<u64>>,
    window: &ApplicationWindow,
) {
    window.set_title(Some(&document.borrow().title()));
    schedule_render(generation, document, preview_slot);

    if let Some(editor) = editor_slot.borrow().clone()
        && editor.web_view.is_visible()
    {
        // resetHistory false: the document changed underneath, but the user's
        // undo stack is still theirs.
        editor.set_text(document.borrow().text(), false);
    }
}

/// The file changed on disk while there are unsaved edits.
fn confirm_external_change(
    window: &ApplicationWindow,
    document: &Rc<RefCell<Document>>,
    preview_slot: &Rc<RefCell<Option<Rc<Preview>>>>,
    editor_slot: &Rc<RefCell<Option<Rc<Editor>>>>,
    generation: &Rc<std::cell::Cell<u64>>,
) {
    let name = document
        .borrow()
        .path()
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "This document".to_string());

    let dialog = gtk4::AlertDialog::builder()
        .message(format!("{name} changed on disk"))
        .detail("You have unsaved edits. Reloading discards them.")
        .buttons(["Keep my edits", "Reload from disk"])
        .cancel_button(0)
        .default_button(0)
        .modal(true)
        .build();

    let document = Rc::clone(document);
    let preview_slot = Rc::clone(preview_slot);
    let editor_slot = Rc::clone(editor_slot);
    let generation = Rc::clone(generation);
    let owned_window = window.clone();
    dialog.choose(Some(window), gtk4::gio::Cancellable::NONE, move |answer| {
        let window = owned_window;
        if answer != Ok(1) {
            return; // keep editing
        }
        if document.borrow_mut().reload().is_ok() {
            adopt_reloaded(&document, &preview_slot, &editor_slot, &generation, &window);
        }
    });
}

/// Re-render the preview after an edit, debounced and superseded-aware.
///
/// Each call bumps the generation; when the timer fires, a render whose
/// generation no longer matches has been overtaken by a newer keystroke and is
/// dropped. That keeps a fast typist from queueing a parse per batch.
fn schedule_render(
    generation: &Rc<std::cell::Cell<u64>>,
    document: &Rc<RefCell<Document>>,
    preview_slot: &Rc<RefCell<Option<Rc<Preview>>>>,
) {
    let current = generation.get().wrapping_add(1);
    generation.set(current);

    let delay = render_debounce(document.borrow().text());
    let generation = Rc::clone(generation);
    let document = Rc::clone(document);
    let preview_slot = Rc::clone(preview_slot);

    gtk4::glib::timeout_add_local_once(delay, move || {
        if generation.get() != current {
            return; // superseded
        }
        let Some(preview) = preview_slot.borrow().clone() else { return };
        let html = render_html(document.borrow().text(), true);
        preview.render(&html, &format!("{}://doc/", crate::assets::SCHEME));
    });
}

/// Save, refreshing the title so the dirty marker clears.
fn save_document(document: &Rc<RefCell<Document>>, window: &ApplicationWindow) {
    if let Err(e) = document.borrow_mut().save() {
        eprintln!("tvmv: saving {}: {e}", document.borrow().path().display());
        let dialog = gtk4::AlertDialog::builder()
            .message("Could not save")
            .detail(format!("{}: {e}", document.borrow().path().display()))
            .modal(true)
            .build();
        dialog.show(Some(window));
        return;
    }
    window.set_title(Some(&document.borrow().title()));
}

/// Ask before dropping unsaved edits, then act on the answer.
fn confirm_discard(window: &ApplicationWindow, document: &Rc<RefCell<Document>>) {
    let name = document
        .borrow()
        .path()
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "this document".to_string());

    let dialog = gtk4::AlertDialog::builder()
        .message(format!("Save changes to {name}?"))
        .detail("Your changes will be lost if you don't save them.")
        .buttons(["Cancel", "Discard", "Save"])
        .cancel_button(0)
        .default_button(2)
        .modal(true)
        .build();

    let document = Rc::clone(document);
    let owned_window = window.clone();
    dialog.choose(Some(window), gtk4::gio::Cancellable::NONE, move |answer| {
        let window = owned_window;
        match answer {
            Ok(1) => {
                // Discard: the guard checks dirtiness, so clear it first.
                document.borrow_mut().mark_clean();
                window.close();
            }
            // A failed save keeps the window open — closing anyway would lose
            // the edits.
            Ok(2) if document.borrow_mut().save().is_ok() => window.close(),
            // Cancel, or the dialog was dismissed.
            _ => {}
        }
    });
}

/// Serial for per-window CSS scoping.
fn next_window_serial() -> usize {
    use std::sync::atomic::{AtomicUsize, Ordering};
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

/// Whether the desktop is asking for a dark appearance.
pub fn system_prefers_dark() -> bool {
    crate::appearance::prefers_dark()
}
