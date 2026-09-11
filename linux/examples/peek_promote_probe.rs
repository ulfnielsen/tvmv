//! End-to-end check that a peek window promotes to a full one.
//!
//! Exercises the path the keybindings call: read the peek window's reading
//! position, `app::promote_peek` with it, close the peek. Then asserts the
//! three things promotion promises — a full window (a peek has no find bar),
//! the editor pane already open, and the reader's place kept.
//!
//! ```sh
//! cargo run --example peek_promote_probe
//! ```
//!
//! A probe rather than a `#[test]` for the same reason as
//! `reload_scroll_probe`: it needs a display, and `cargo test` must not.

use std::cell::Cell;
use std::io::Write;
use std::path::PathBuf;
use std::process::ExitCode;
use std::rc::Rc;

use gtk4::prelude::*;
use tvmv::app;
use webkit6::prelude::WebViewExt;

/// Where the peek window is scrolled to before it is promoted.
const TARGET: f64 = 0.5;
const TOLERANCE: f64 = 0.05;

/// What the probe found in the promoted window.
#[derive(Default)]
struct Verdict {
    /// A find bar exists, so this is a full window rather than another peek.
    full_chrome: Cell<bool>,
    /// The editor pane is open, because `Ctrl+E` was the promoting gesture.
    editing: Cell<bool>,
    /// Where the promoted window ended up.
    ratio: Cell<f64>,
}

fn main() -> ExitCode {
    tvmv::startup::apply_opt_out();
    tvmv::startup::force_dmabuf_renderer();

    let dir = std::env::temp_dir().join(format!("tvmv-promote-probe-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("a scratch directory");
    let path = dir.join("probe.md");
    write_document(&path);

    let application = gtk4::Application::builder()
        .application_id("dk.dyregod.tvmv.peek-promote-probe")
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();

    let verdict = Rc::new(Verdict::default());
    verdict.ratio.set(f64::NAN);

    application.connect_activate({
        let path = path.clone();
        let verdict = Rc::clone(&verdict);
        move |application| {
            let Some(peek) = app::open_peek(application, &path) else {
                eprintln!("FAIL: the peek window did not open");
                application.quit();
                return;
            };

            // The peek path takes no render-complete hook, so the probe waits
            // rather than being told. Generous: a cold WebProcess plus KaTeX.
            let application = application.clone();
            let verdict = Rc::clone(&verdict);
            let path = path.clone();
            after(2500, move || {
                let Some(view) = preview_view(peek.upcast_ref()) else {
                    eprintln!("FAIL: no preview web view in the peek window");
                    application.quit();
                    return;
                };
                eval(&view, &format!("window.tvmv.setScrollRatio({TARGET});"));

                after(400, move || {
                    read(&view, move |before| {
                        println!("peek scrolled to {before:.3}");
                        assert!(
                            (before - TARGET).abs() < TOLERANCE,
                            "the peek window is not scrollable — the probe proves nothing"
                        );

                        // Exactly what Ctrl+E in a peek window does.
                        let promoted = app::promote_peek(
                            &application,
                            &path,
                            Some(before),
                            true,
                        );
                        let Some(promoted) = promoted else {
                            eprintln!("FAIL: promote_peek opened nothing");
                            application.quit();
                            return;
                        };
                        peek.close();
                        println!("promoted; peek closed");

                        // Read the promoted window once its own render has
                        // settled and the staged position has been restored.
                        after(3000, move || {
                            verdict.full_chrome.set(has_find_bar(promoted.upcast_ref()));
                            verdict.editing.set(editor_is_visible(promoted.upcast_ref()));
                            let Some(view) = preview_view(promoted.upcast_ref()) else {
                                eprintln!("FAIL: no preview web view in the promoted window");
                                application.quit();
                                return;
                            };
                            read(&view, move |ratio| {
                                verdict.ratio.set(ratio);
                                application.quit();
                            });
                        });
                    });
                });
            });
        }
    });

    application.run_with_args::<&str>(&[]);
    let _ = std::fs::remove_dir_all(&dir);

    let ratio = verdict.ratio.get();
    println!("full chrome: {}", verdict.full_chrome.get());
    println!("editor open: {}", verdict.editing.get());
    println!("position:    {ratio:.3}");

    let mut failed = false;
    if !verdict.full_chrome.get() {
        eprintln!("FAIL: the promoted window has no find bar — it is still chromeless");
        failed = true;
    }
    if !verdict.editing.get() {
        eprintln!("FAIL: Ctrl+E promoted without opening the editor");
        failed = true;
    }
    if ratio.is_nan() || (ratio - TARGET).abs() >= TOLERANCE {
        eprintln!("FAIL: expected ~{TARGET:.3}, got {ratio:.3}");
        failed = true;
    }
    if failed {
        return ExitCode::FAILURE;
    }
    println!("PASS: promotion keeps the place, the chrome, and the gesture");
    ExitCode::SUCCESS
}

/// Long enough to scroll, so a position exists to carry over.
fn write_document(path: &PathBuf) {
    let mut text = String::from("# Promotion probe\n\n");
    for i in 1..=60 {
        text.push_str(&format!(
            "## Section {i}\n\nProse for section {i}, long enough to take a line or two of the \
             measure so the document scrolls rather than fitting on one screen.\n\n"
        ));
    }
    let mut file = std::fs::File::create(path).expect("the probe document");
    file.write_all(text.as_bytes()).expect("writing the document");
}

// --- widget-tree inspection ------------------------------------------------
//
// The probe holds an `ApplicationWindow`, not the `DocumentWindow` behind it
// (that lives in `app`'s own registry), so what it can check is what the window
// actually contains.

fn descendants(widget: &gtk4::Widget) -> Vec<gtk4::Widget> {
    let mut found = Vec::new();
    let mut child = widget.first_child();
    while let Some(node) = child {
        found.push(node.clone());
        found.extend(descendants(&node));
        child = node.next_sibling();
    }
    found
}

fn web_views(window: &gtk4::Widget) -> Vec<webkit6::WebView> {
    descendants(window)
        .into_iter()
        .filter_map(|w| w.downcast::<webkit6::WebView>().ok())
        .collect()
}

/// The preview view, told apart from the editor by the page it loaded.
fn preview_view(window: &gtk4::Widget) -> Option<webkit6::WebView> {
    web_views(window)
        .into_iter()
        .find(|v| v.uri().is_some_and(|u| u.ends_with("template.html")))
}

fn editor_is_visible(window: &gtk4::Widget) -> bool {
    web_views(window)
        .iter()
        .any(|v| v.is_visible() && v.uri().is_some_and(|u| u.ends_with("editor.html")))
}

/// Only a full window builds one, so it stands in for "has chrome".
fn has_find_bar(window: &gtk4::Widget) -> bool {
    descendants(window)
        .into_iter()
        .any(|w| w.downcast::<gtk4::SearchBar>().is_ok())
}

// --- JS helpers ------------------------------------------------------------

fn eval(web_view: &webkit6::WebView, script: &str) {
    web_view.evaluate_javascript(script, None, None, gtk4::gio::Cancellable::NONE, |_| {});
}

fn read(web_view: &webkit6::WebView, then: impl FnOnce(f64) + 'static) {
    web_view.evaluate_javascript(
        "window.tvmv.getScrollRatio()",
        None,
        None,
        gtk4::gio::Cancellable::NONE,
        move |result| {
            let value = result
                .ok()
                .and_then(|v| v.to_json(0))
                .and_then(|json| json.as_str().parse::<f64>().ok())
                .unwrap_or(f64::NAN);
            then(value);
        },
    );
}

fn after(millis: u64, action: impl FnOnce() + 'static) {
    gtk4::glib::timeout_add_local_once(std::time::Duration::from_millis(millis), action);
}
