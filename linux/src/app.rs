//! The GTK application.
//!
//! `HANDLES_OPEN` gives D-Bus activation for free: `tvmv a.md b.md` against an
//! already-running instance is one IPC message and the windows appear without a
//! process launch. That reproduces the Mac app's "reuses a running instance"
//! behaviour with none of its code.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use gtk4::gio::ApplicationFlags;
use gtk4::prelude::*;
use gtk4::{Application, ApplicationWindow, glib};

use crate::resources;
use crate::settings::Settings;
use crate::window::DocumentWindow;

/// Push settings into every open window.
pub fn apply_settings_to_all(settings: &Settings) {
    OPEN_WINDOWS.with(|open| {
        for doc in open.borrow().iter() {
            doc.apply_settings(settings);
        }
    });
}

/// The active settings, shared by every window and the settings dialog.
///
/// One process-wide copy: settings are global, and two windows disagreeing
/// about the theme after a change would be a bug, not a feature.
pub fn shared_settings() -> Rc<RefCell<Settings>> {
    thread_local! {
        static SETTINGS: Rc<RefCell<Settings>> = {
            let (settings, error) = Settings::load();
            if let Some(e) = error {
                eprintln!("tvmv: {e}");
            }
            Rc::new(RefCell::new(settings))
        };
    }
    SETTINGS.with(Rc::clone)
}

pub const APP_ID: &str = "dk.dyregod.tvmv";

pub fn run(paths: Vec<PathBuf>) -> glib::ExitCode {
    run_with_hint(paths, "")
}

/// Run, opening `paths` with `hint` — `PEEK_HINT` for a preview.
pub fn run_with_hint(paths: Vec<PathBuf>, hint: &'static str) -> glib::ExitCode {
    let app = Application::builder()
        .application_id(APP_ID)
        .flags(ApplicationFlags::HANDLES_OPEN)
        .build();

    // The hint travels with `g_application_open`, including to an
    // already-running instance — which is how `--peek` reuses the warm process
    // instead of paying a cold start for a preview.
    app.connect_open(|app, files, hint| {
        let peek = hint == PEEK_HINT;
        for file in files {
            if let Some(path) = file.path() {
                if peek {
                    open_peek(app, &path);
                } else {
                    open_window(app, &path, None);
                }
            }
        }
    });

    // Launched with no document — from the app menu, or a bare `tvmv`. Ask for
    // one rather than exiting silently, which looks like the app failed to
    // start. `GtkFileDialog` routes through the XDG portal, so KDE users get the
    // Plasma chooser.
    app.connect_activate(|app| {
        let filter = gtk4::FileFilter::new();
        filter.set_name(Some("Markdown"));
        filter.add_mime_type("text/markdown");
        for pattern in ["*.md", "*.markdown", "*.mdown", "*.mkd"] {
            filter.add_pattern(pattern);
        }
        let filters = gtk4::gio::ListStore::new::<gtk4::FileFilter>();
        filters.append(&filter);

        let dialog = gtk4::FileDialog::builder()
            .title("Open Markdown Document")
            .filters(&filters)
            .default_filter(&filter)
            .modal(true)
            .build();

        // Without this the application exits the moment `activate` returns,
        // because it has no windows yet — taking the dialog with it.
        let hold = app.hold();
        let app = app.clone();
        dialog.open(None::<&ApplicationWindow>, gtk4::gio::Cancellable::NONE, move |result| {
            let _hold = hold;
            // Cancelled: nothing to do, and the hold drops so we exit.
            let Ok(file) = result else { return };
            match file.path() {
                Some(path) => {
                    open_window(&app, &path, None);
                }
                // A non-local file (a remote share via the portal) has no
                // path; the renderer needs one for `tvmv-asset://doc/`.
                None => eprintln!("tvmv: that document is not a local file"),
            }
        });
    });

    if hint.is_empty() {
        // Paths go through GApplication rather than being captured, so a second
        // invocation routes to the running instance instead of this one.
        let args: Vec<String> = std::iter::once("tvmv".to_string())
            .chain(paths.iter().map(|p| p.to_string_lossy().into_owned()))
            .collect();
        return app.run_with_args(&args);
    }

    // `open` with a hint has no command-line spelling, so register first and
    // call it directly; registration is what forwards to a running primary.
    if let Err(e) = app.register(gtk4::gio::Cancellable::NONE) {
        eprintln!("tvmv: {e}");
        return glib::ExitCode::FAILURE;
    }
    let files: Vec<gtk4::gio::File> = paths.iter().map(gtk4::gio::File::for_path).collect();
    app.open(&files, hint);

    // Always run, even when remote: `run` is what unregisters from D-Bus, and
    // returning without it logs "did not unregister from D-Bus before
    // destruction". A remote instance returns from it immediately.
    app.run_with_args::<&str>(&[])
}

// Windows currently open.
//
// GTK's `Application` keeps the `GtkWindow` alive, but not our `DocumentWindow`
// — and that owns the file watcher. Dropping it stopped live reload the instant
// the window opened, silently: the window looked perfectly normal, it just never
// reloaded. Held here until the window is destroyed.
//
// GTK is single-threaded, so thread-local is the right scope.
thread_local! {
    static OPEN_WINDOWS: RefCell<Vec<DocumentWindow>> = const { RefCell::new(Vec::new()) };
}

/// `GApplication::open` hint that marks a preview request.
pub const PEEK_HINT: &str = "peek";

/// Open a chromeless preview window.
pub fn open_peek(app: &Application, path: &Path) -> Option<ApplicationWindow> {
    let web_dir = resources::web_dir()?;
    let settings = shared_settings();
    let doc = DocumentWindow::peek(app, &web_dir, path, &settings.borrow());
    let window = doc.window.clone();

    window.connect_destroy(|window| {
        OPEN_WINDOWS.with(|open| open.borrow_mut().retain(|doc| doc.window != *window));
    });
    OPEN_WINDOWS.with(|open| open.borrow_mut().push(doc));

    window.present();
    Some(window)
}

pub fn open_window(
    app: &Application,
    path: &Path,
    on_render_complete: Option<crate::window::OnRenderComplete>,
) -> Option<ApplicationWindow> {
    let Some(web_dir) = resources::web_dir() else {
        eprintln!(
            "tvmv: could not find the web/ resources.\n\
             Set TVMV_WEB_DIR, or install them to /usr/share/tvmv/web."
        );
        return None;
    };

    let settings = shared_settings();
    let doc = DocumentWindow::new(app, &web_dir, path, &settings.borrow(), on_render_complete);
    let window = doc.window.clone();

    // Drop our state when the window goes away, so watcher threads do not
    // outlive their windows.
    window.connect_destroy(|window| {
        OPEN_WINDOWS.with(|open| open.borrow_mut().retain(|doc| doc.window != *window));
    });
    OPEN_WINDOWS.with(|open| open.borrow_mut().push(doc));

    window.present();
    Some(window)
}
