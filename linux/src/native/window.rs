//! A window around the native view, for `tvmv --native FILE` while the
//! native editor is being built (build step 1 of
//! `docs/superpowers/specs/2026-10-21-linux-native-editor-design.md`). Step 2
//! moves the view into `DocumentWindow` and retires this.
//!
//! Ctrl+E edits, Ctrl+S saves, Ctrl+W closes.

use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{gdk, gio, glib};

use crate::document::Document;
use crate::settings::Settings;

use super::document_view::DocumentView;
use super::theme::NativeTheme;

pub fn run(path: &Path) -> glib::ExitCode {
    let app = gtk4::Application::builder()
        .application_id("dk.dyregod.tvmv.native")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    let path = path.to_path_buf();
    app.connect_activate(move |app| {
        open(app, &path);
    });
    app.run_with_args::<&str>(&[])
}

pub fn open(app: &gtk4::Application, path: &Path) -> gtk4::ApplicationWindow {
    let (settings, _) = Settings::load();
    let theme = NativeTheme::from_settings(&settings, crate::appearance::prefers_dark());
    let document = Rc::new(RefCell::new(Document::load(path).unwrap_or_else(|e| {
        eprintln!("tvmv: {}: {e}", path.display());
        Document::empty(path)
    })));
    let doc = DocumentView::new(theme);
    doc.load(document.borrow().text().to_string());

    let window = gtk4::ApplicationWindow::builder()
        .application(app)
        .default_width(900)
        .default_height(1000)
        .build();
    let scroller = gtk4::ScrolledWindow::new();
    scroller.set_hscrollbar_policy(gtk4::PolicyType::Never);
    scroller.set_child(Some(&doc.view));
    window.set_child(Some(&scroller));

    let title = {
        let window = window.clone();
        let document = Rc::clone(&document);
        let doc = Rc::clone(&doc);
        move || {
            let d = document.borrow();
            let dirty = doc.text() != d.last_saved();
            let mode = if doc.is_editable() { " — editing" } else { "" };
            let name = d.path().file_name().map_or_else(|| "tvmv".into(), |n| n.to_string_lossy().into_owned());
            window.set_title(Some(&format!("{}{name}{mode}", if dirty { "• " } else { "" })));
        }
    };
    title();
    doc.set_on_changed(title.clone());
    let parent = window.clone();
    doc.set_on_follow_link(move |url| {
        if url.starts_with('#') {
            return;
        }
        gtk4::UriLauncher::new(url).launch(Some(&parent), gio::Cancellable::NONE, |result| {
            if let Err(e) = result {
                eprintln!("tvmv: opening link: {e}");
            }
        });
    });

    let keys = gtk4::EventControllerKey::new();
    keys.set_propagation_phase(gtk4::PropagationPhase::Capture);
    let window_ref = window.clone();
    let doc_ref = Rc::clone(&doc);
    keys.connect_key_pressed(move |_, key, _, state| {
        if !state.contains(gdk::ModifierType::CONTROL_MASK) {
            return glib::Propagation::Proceed;
        }
        match key.to_lower() {
            gdk::Key::e if doc_ref.is_loaded() => {
                doc_ref.set_editable(!doc_ref.is_editable());
                if doc_ref.is_editable() {
                    doc_ref.view.grab_focus();
                }
                title();
            }
            gdk::Key::s => {
                let mut d = document.borrow_mut();
                d.set_text(doc_ref.text());
                if let Err(e) = d.save() {
                    eprintln!("tvmv: saving {}: {e}", d.path().display());
                }
                drop(d);
                title();
            }
            gdk::Key::w => window_ref.close(),
            _ => return glib::Propagation::Proceed,
        }
        glib::Propagation::Stop
    });
    window.add_controller(keys);
    window.present();
    doc.view.grab_focus();
    window
}
