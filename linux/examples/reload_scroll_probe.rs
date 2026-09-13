//! End-to-end check that a live reload keeps the reading position.
//!
//! The unit tests in `preview.rs` cover the decode and the emitted script, but
//! not the thing that actually matters: that the capture, the re-render and the
//! restore land in the right order against a real WebKit page whose height
//! changes under the lazy enrichment passes. That needs the whole stack — the
//! inotify watcher, the debounces, the promise chain behind `renderComplete` —
//! so it is a probe rather than a `#[test]`: it wants a display, and `cargo
//! test` must stay runnable without one.
//!
//! ```sh
//! cargo run --example reload_scroll_probe
//! ```
//!
//! Scrolls half way down a generated document, rewrites the file on disk, and
//! reports the position after the reload settles. Exit status is the verdict.

use std::cell::Cell;
use std::io::Write;
use std::path::PathBuf;
use std::process::ExitCode;
use std::rc::Rc;

use gtk4::prelude::*;
use tvmv::app;

/// Where we scroll to before the reload, as a fraction of the document.
const TARGET: f64 = 0.5;

/// How far the restored position may drift and still count.
const TOLERANCE: f64 = 0.05;

/// Sections in the document before and after the reload.
///
/// **The lengths have to differ for this probe to discriminate.** Replacing
/// `#content` does not reset WebKitGTK's scroll offset, so with an
/// equal-length document the position survives whether or not anything
/// restores it — an earlier version of this probe passed with the restore
/// commented out, and proved nothing. Shortening the document to a third
/// forces the difference into the open: the raw offset clamps to the new
/// bottom, while a ratio restore lands back at the same relative place.
const SECTIONS_BEFORE: usize = 60;
const SECTIONS_AFTER: usize = 20;

fn main() -> ExitCode {
    tvmv::startup::apply_opt_out();
    tvmv::startup::force_dmabuf_renderer();

    let dir = std::env::temp_dir().join(format!("tvmv-reload-probe-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("a scratch directory");
    let path = dir.join("probe.md");
    write_document(&path, "first", SECTIONS_BEFORE);

    let application = gtk4::Application::builder()
        .application_id("dk.dyregod.tvmv.reload-scroll-probe")
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();

    // Set from the render that follows the reload; read after the loop stops.
    let restored = Rc::new(Cell::new(f64::NAN));

    application.connect_activate({
        let path = path.clone();
        let restored = Rc::clone(&restored);
        move |application| {
            let renders = Rc::new(Cell::new(0u32));

            let on_render_complete: tvmv::window::OnRenderComplete = Box::new({
                let path = path.clone();
                let restored = Rc::clone(&restored);
                let application = application.clone();
                move |preview| {
                    let nth = renders.get() + 1;
                    renders.set(nth);

                    match nth {
                        // First render: take up the reading position, confirm it
                        // stuck, then change the file underneath us.
                        1 => {
                            preview.eval(&format!("window.tvmv.setScrollRatio({TARGET});"));
                            let path = path.clone();
                            let preview = preview.web_view.clone();
                            after(300, move || {
                                ratio(&preview, move |before| {
                                    println!("scrolled to {before:.3} (asked for {TARGET:.3})");
                                    assert!(
                                        (before - TARGET).abs() < TOLERANCE,
                                        "the document is not scrollable — the probe proves nothing"
                                    );
                                    write_document(&path, "second", SECTIONS_AFTER);
                                    println!("rewrote the file; waiting for the reload");
                                });
                            });
                        }
                        // The reload's render. `restore_scroll_ratio` has been
                        // called by now, but it waits two frames, so do the same.
                        _ => {
                            let restored = Rc::clone(&restored);
                            let application = application.clone();
                            let view = preview.web_view.clone();
                            // Does the page get frames at all? The restore's
                            // settle depends on it.
                            preview.eval(
                                "window.__raf=0;requestAnimationFrame(function(){window.__raf=1;                                 requestAnimationFrame(function(){window.__raf=2;});});",
                            );
                            for delay in [30u64, 150, 400, 1200] {
                                let view = view.clone();
                                after(delay, move || {
                                    metrics(&view, move |m| println!("  +{delay}ms {m}"));
                                });
                            }
                            after(2000, move || {
                                ratio(&view, move |after_reload| {
                                    restored.set(after_reload);
                                    application.quit();
                                });
                            });
                        }
                    }
                }
            });

            if app::open_window(application, &path, Some(on_render_complete)).is_none() {
                application.quit();
            }

            // A reload that never arrives must not hang a probe run.
            let application = application.clone();
            after(20_000, move || {
                eprintln!("probe: timed out waiting for the reload");
                application.quit();
            });
        }
    });

    application.run_with_args::<&str>(&[]);
    let _ = std::fs::remove_dir_all(&dir);

    let restored = restored.get();
    if restored.is_nan() {
        eprintln!("FAIL: the reload never re-rendered");
        return ExitCode::FAILURE;
    }
    println!("position after reload: {restored:.3}");
    if (restored - TARGET).abs() < TOLERANCE {
        println!("PASS: the reading position survived the reload");
        ExitCode::SUCCESS
    } else {
        eprintln!("FAIL: expected ~{TARGET:.3}, got {restored:.3}");
        ExitCode::FAILURE
    }
}

/// A document long enough to scroll, and long enough that the enrichment passes
/// change its height after `renderComplete` — a fence and some math per section,
/// so highlight.js and KaTeX both have work to do.
fn write_document(path: &PathBuf, marker: &str, sections: usize) {
    let mut text = format!("# Reload probe ({marker})\n\n");
    for i in 1..=sections {
        text.push_str(&format!(
            "## Section {i}\n\nProse for section {i}, long enough to take a line or two of \
             the measure so the document scrolls rather than fitting on one screen.\n\n\
             ```rust\nfn section_{i}() -> usize {{ {i} }}\n```\n\n\
             Inline math $x_{{{i}}} = \\sqrt{{{i}}}$ follows.\n\n"
        ));
    }
    // Atomic, the way an editor saves: the watcher has to survive the rename.
    let temp = path.with_extension("md.tmp");
    let mut file = std::fs::File::create(&temp).expect("a temp file");
    file.write_all(text.as_bytes()).expect("writing the document");
    file.sync_all().expect("flushing the document");
    std::fs::rename(&temp, path).expect("renaming over the document");
}

/// Read the page's scroll position.
fn ratio(web_view: &webkit6::WebView, then: impl FnOnce(f64) + 'static) {
    use webkit6::prelude::*;
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

/// scrollY / maxScroll / scrollHeight, as one line, for tracing the restore.
fn metrics(web_view: &webkit6::WebView, then: impl FnOnce(String) + 'static) {
    use webkit6::prelude::*;
    let js = "(function(){var d=document.documentElement;\
        return 'y='+window.scrollY+' max='+(d.scrollHeight-window.innerHeight)+\
        ' h='+d.scrollHeight+' r='+window.tvmv.getScrollRatio().toFixed(3)+\
        ' raf='+window.__raf;})()";
    web_view.evaluate_javascript(js, None, None, gtk4::gio::Cancellable::NONE, move |result| {
        let text = result
            .ok()
            .and_then(|v| v.to_json(0))
            .map(|j| j.as_str().trim_matches('"').to_string())
            .unwrap_or_else(|| "unavailable".to_string());
        then(text);
    });
}

fn after(millis: u64, action: impl FnOnce() + 'static) {
    gtk4::glib::timeout_add_local_once(std::time::Duration::from_millis(millis), action);
}
