//! CLI entry point.
//!
//!   tvmv <file.md> ...              open document windows
//!   tvmv --html <file.md>           render to stdout (no GUI)
//!   tvmv --snapshot <out.png> <f>   render offscreen and write a PNG
//!   tvmv --pdf <out.pdf> <file.md>  render straight to PDF, no window
//!   tvmv --peek <file.md>            chromeless preview, Escape to close
//!   tvmv --thumbnail <in> <out> <n>  draw a file-manager thumbnail (no WebKit)
//!
//! Diagnostics:
//!   tvmv --frame-bench <f> [--idle] measure frames actually painted
//!   tvmv --webkit-features [filter] list WebKit runtime features

use std::cell::RefCell;
use std::path::PathBuf;
use std::process::ExitCode;
use std::rc::Rc;

use gtk4::prelude::*;
use webkit6::prelude::*;

use tvmv::{app, render};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();

    // Only for the modes that actually start WebKit. `--thumbnail` and `--html`
    // never do, and a file manager running the thumbnailer over a directory
    // should not get a sandbox warning per file.
    let uses_webkit = !matches!(args.first().map(String::as_str), Some("--thumbnail" | "--html"));
    if uses_webkit {
        // Both must happen before any WebKit type is touched.
        tvmv::startup::apply_opt_out();
        tvmv::startup::force_dmabuf_renderer();
    }

    match args.first().map(String::as_str) {
        // No document: still start the app, which asks for one. Exiting with a
        // usage message here makes launching from the app menu look like a
        // crash — the desktop passes no arguments.
        None => exit_code(app::run(Vec::new())),
        Some("--html") => match args.get(1) {
            Some(path) => render_to_stdout(path, args.iter().any(|a| a == "--source-pos")),
            None => {
                eprintln!("tvmv: --html needs a file");
                ExitCode::FAILURE
            }
        },
        Some("--snapshot") => match (args.get(1), args.get(2)) {
            (Some(out), Some(input)) => snapshot(PathBuf::from(out), PathBuf::from(input)),
            _ => {
                eprintln!("tvmv: --snapshot needs an output PNG and an input file");
                ExitCode::FAILURE
            }
        },
        // <input> <output> <size>: the argument order the freedesktop
        // .thumbnailer spec passes (%i %o %s).
        Some("--peek") => match args.get(1) {
            Some(input) => exit_code(app::run_with_hint(
                vec![PathBuf::from(input)],
                app::PEEK_HINT,
            )),
            None => {
                eprintln!("tvmv: --peek needs a file");
                ExitCode::FAILURE
            }
        },
        Some("--thumbnail") => match (args.get(1), args.get(2), args.get(3)) {
            (Some(input), Some(output), size) => thumbnail(
                PathBuf::from(input),
                PathBuf::from(output),
                size.and_then(|s| s.parse().ok()).unwrap_or(256),
            ),
            _ => {
                eprintln!("tvmv: --thumbnail needs <input.md> <output.png> [size]");
                ExitCode::FAILURE
            }
        },
        Some("--pdf") => match (args.get(1), args.get(2)) {
            (Some(out), Some(input)) => export_pdf(PathBuf::from(out), PathBuf::from(input)),
            _ => {
                eprintln!("tvmv: --pdf needs an output PDF and an input file");
                ExitCode::FAILURE
            }
        },
        Some("--frame-bench") => match args.get(1) {
            Some(input) => {
                frame_bench(PathBuf::from(input), !args.iter().any(|a| a == "--idle"))
            }
            None => {
                eprintln!("tvmv: --frame-bench needs a file");
                ExitCode::FAILURE
            }
        },
        Some("--webkit-features") => {
            list_features(args.get(1).map(String::as_str).unwrap_or(""));
            ExitCode::SUCCESS
        }
        Some(_) => {
            let paths: Vec<PathBuf> = args.iter().map(PathBuf::from).collect();
            if app::run(paths) == gtk4::glib::ExitCode::SUCCESS {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
    }
}

fn render_to_stdout(path: &str, source_pos: bool) -> ExitCode {
    match std::fs::read_to_string(path) {
        Ok(markdown) => {
            print!("{}", render::render_html(&markdown, source_pos));
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("tvmv: {path}: {e}");
            ExitCode::FAILURE
        }
    }
}

fn snapshot(output: PathBuf, input: PathBuf) -> ExitCode {
    let application = gtk4::Application::builder()
        .application_id("dk.dyregod.tvmv.snapshot")
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();

    application.connect_activate(move |application| {
        let output = output.clone();
        let application_for_quit = application.clone();

        let on_render_complete: tvmv::window::OnRenderComplete = Box::new(move |preview| {
            let output = output.clone();
            let application = application_for_quit.clone();
            let web_view = preview.web_view.clone();

            // renderComplete means the DOM is final; give the compositor a beat
            // to actually paint it before capturing.
            gtk4::glib::timeout_add_local_once(std::time::Duration::from_millis(400), move || {
                web_view.snapshot(
                    webkit6::SnapshotRegion::FullDocument,
                    webkit6::SnapshotOptions::NONE,
                    gtk4::gio::Cancellable::NONE,
                    move |result| {
                        match result {
                            Ok(texture) => match texture.save_to_png(&output) {
                                Ok(()) => println!("wrote {}", output.display()),
                                Err(e) => eprintln!("tvmv: writing {}: {e}", output.display()),
                            },
                            Err(e) => eprintln!("tvmv: snapshot failed: {e}"),
                        }
                        application.quit();
                    },
                );
            });
        });

        if app::open_window(application, &input, Some(on_render_complete)).is_none() {
            application.quit();
        }
    });

    exit_code(application.run_with_args::<&str>(&[]))
}

/// Draw a file-manager thumbnail.
///
/// No GTK application, no window, and above all no WebKit: a file manager runs
/// this over every file in a directory. Only a bounded prefix of the document is
/// read, so a multi-megabyte file costs the same as a small one.
fn thumbnail(input: PathBuf, output: PathBuf, size: i32) -> ExitCode {
    use std::io::Read;

    let Ok(mut file) = std::fs::File::open(&input) else {
        eprintln!("tvmv: {}: cannot open", input.display());
        return ExitCode::FAILURE;
    };
    let mut buffer = vec![0u8; tvmv::card::READ_LIMIT];
    let read = file.read(&mut buffer).unwrap_or(0);
    buffer.truncate(read);
    // Lossy on purpose: something mislabelled as markdown must still draw
    // rather than fail the file manager's thumbnail run.
    let text = String::from_utf8_lossy(&buffer);

    let fallback = input
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Untitled".to_string());
    let summary = tvmv::card::summarize(&text, &fallback, 8);

    let surface = match tvmv::card::draw(&summary, size.clamp(16, 1024), false) {
        Ok(surface) => surface,
        Err(e) => {
            eprintln!("tvmv: drawing thumbnail: {e}");
            return ExitCode::FAILURE;
        }
    };

    match std::fs::File::create(&output).map(|mut f| surface.write_to_png(&mut f)) {
        Ok(Ok(())) => ExitCode::SUCCESS,
        Ok(Err(e)) => {
            eprintln!("tvmv: writing {}: {e}", output.display());
            ExitCode::FAILURE
        }
        Err(e) => {
            eprintln!("tvmv: writing {}: {e}", output.display());
            ExitCode::FAILURE
        }
    }
}

/// Render a document straight to PDF, with no window interaction.
///
/// Exercises the same `WebKitPrintOperation` path the Print command uses, so the
/// shared `@media print` rules are what produce the output.
fn export_pdf(output: PathBuf, input: PathBuf) -> ExitCode {
    let application = gtk4::Application::builder()
        .application_id("dk.dyregod.tvmv.pdf")
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();

    application.connect_activate(move |application| {
        let output = output.clone();
        let application_for_quit = application.clone();

        let on_render_complete: tvmv::window::OnRenderComplete = Box::new(move |preview| {
            let output = output.clone();
            let application = application_for_quit.clone();
            let web_view = preview.web_view.clone();

            // renderComplete means the DOM is final, including the lazy KaTeX and
            // Mermaid passes; printing before that would drop them.
            gtk4::glib::timeout_add_local_once(std::time::Duration::from_millis(300), move || {
                let application = application.clone();
                let output = output.clone();
                tvmv::print::export_pdf(&web_view, &output.clone(), move |ok| {
                    if ok {
                        println!("wrote {}", output.display());
                    }
                    application.quit();
                });
            });
        });

        if app::open_window(application, &input, Some(on_render_complete)).is_none() {
            application.quit();
        }
    });

    exit_code(application.run_with_args::<&str>(&[]))
}

/// Measure frames GTK **actually paints**.
///
/// An earlier version of this measured `requestAnimationFrame` cadence instead,
/// and that was actively misleading: rAF is driven by vsync and keeps ticking at
/// a clean 16 ms even while paints are being dropped. It reported a healthy
/// 60 fps for a window that was visibly sluggish. The frame clock's `after-paint`
/// is the honest signal — one tick per frame the toolkit actually put on screen.
///
/// See `examples/gtk_frame_probe.rs` for the WebKit-free control.
fn frame_bench(input: PathBuf, scroll: bool) -> ExitCode {
    // Driven from requestAnimationFrame, not setInterval: timer callbacks can be
    // coalesced, which would cap the damage rate and be misread as dropped frames.
    const SCROLL_JS: &str = r#"
        (function () {
            var d = 24;
            function step() {
                if ((window.scrollY + window.innerHeight) >= document.body.scrollHeight - 2) d = -Math.abs(d);
                if (window.scrollY <= 0) d = Math.abs(d);
                window.scrollBy(0, d);
                requestAnimationFrame(step);
            }
            requestAnimationFrame(step);
        })();
    "#;

    let application = gtk4::Application::builder()
        .application_id("dk.dyregod.tvmv.framebench")
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();

    application.connect_activate(move |application| {
        let application_for_quit = application.clone();
        let window_slot: Rc<RefCell<Option<gtk4::ApplicationWindow>>> = Rc::new(RefCell::new(None));
        let slot = Rc::clone(&window_slot);

        let on_render_complete: tvmv::window::OnRenderComplete = Box::new(move |preview| {
            // --anim animates a pure CSS transform: work only a compositor can
            // do. If this reaches the refresh rate while scrolling does not,
            // accelerated compositing is alive and it is *scrolling* that is
            // un-composited — which distinguishes an engine gap from a broken
            // GL setup.
            if std::env::var("TVMV_ANIM").as_deref() == Ok("1") {
                preview.eval(
                    "(function(){var e=document.createElement('div');\
                     e.style.cssText='position:fixed;top:0;left:0;width:200px;height:200px;background:#B83F12;z-index:9999';\
                     document.body.appendChild(e);var x=0;\
                     function s(){x=(x+6)%800;e.style.transform='translateX('+x+'px)';requestAnimationFrame(s);}\
                     requestAnimationFrame(s);})();",
                );
            } else if scroll {
                preview.eval(SCROLL_JS);
            }

            let Some(window) = slot.borrow().clone() else { return };
            let Some(clock) = WidgetExt::frame_clock(&window) else {
                eprintln!("tvmv: no frame clock");
                return;
            };

            let refresh_ms = clock
                .current_timings()
                .map(|t| t.refresh_interval() as f64 / 1000.0)
                .unwrap_or(-1.0);
            eprintln!("  frame clock: refresh_interval={refresh_ms:.2}ms");

            let stamps: Rc<RefCell<Vec<i64>>> = Rc::new(RefCell::new(Vec::new()));
            let recorder = Rc::clone(&stamps);
            clock.connect_after_paint(move |clock| {
                recorder.borrow_mut().push(clock.frame_time());
            });
            clock.begin_updating();

            let application = application_for_quit.clone();
            let refresh = clock.clone();
            gtk4::glib::timeout_add_local_once(std::time::Duration::from_millis(5000), move || {
                refresh.end_updating();
                report_frame_clock(&stamps.borrow(), refresh_ms);
                application.quit();
            });
        });

        match app::open_window(application, &input, Some(on_render_complete)) {
            Some(window) => *window_slot.borrow_mut() = Some(window),
            None => application.quit(),
        }
    });

    exit_code(application.run_with_args::<&str>(&[]))
}

fn report_frame_clock(stamps: &[i64], refresh_ms: f64) {
    if stamps.len() < 5 {
        eprintln!("tvmv: only {} painted frames in 5s — that is the finding", stamps.len());
        return;
    }
    let mut gaps: Vec<f64> = stamps.windows(2).map(|w| (w[1] - w[0]) as f64 / 1000.0).collect();
    let painted = gaps.len();
    let span_ms: f64 = gaps.iter().sum();
    gaps.sort_by(|a, b| a.partial_cmp(b).unwrap());

    let median = gaps[painted / 2];
    // How many refresh intervals each painted frame actually spans. 1.0 is
    // perfect; the quantisation to whole numbers is the useful part.
    let vsyncs = if refresh_ms > 0.0 { median / refresh_ms } else { f64::NAN };

    println!(
        "painted={painted} in {:.1}s  ({:.1} fps)  median={median:.1}ms  p95={:.1}ms  worst={:.1}ms  = {vsyncs:.1} vsyncs/frame",
        span_ms / 1000.0,
        painted as f64 / (span_ms / 1000.0),
        gaps[(painted * 95) / 100],
        gaps[painted - 1],
    );
}

/// List WebKit runtime features whose identifier matches `filter`, with their
/// current state. A diagnostic for performance work: WebKit gates a lot of
/// behaviour behind these, and guessing which are on is how one ends up
/// "fixing" something that was never off.
fn list_features(filter: &str) {
    let Some(features) = webkit6::Settings::all_features() else {
        eprintln!("tvmv: no feature list available");
        return;
    };
    let defaults = webkit6::Settings::new();
    println!(
        "settings defaults: enable_smooth_scrolling={} hardware_acceleration_policy={:?}\n",
        defaults.enables_smooth_scrolling(),
        defaults.hardware_acceleration_policy()
    );

    let needle = filter.to_ascii_lowercase();
    for i in 0..features.length() {
        let Some(feature) = features.get(i) else { continue };
        let id = feature.identifier().unwrap_or_default().to_string();
        let category = feature.category().unwrap_or_default().to_string();
        if !needle.is_empty()
            && !id.to_ascii_lowercase().contains(&needle)
            && !category.to_ascii_lowercase().contains(&needle)
        {
            continue;
        }
        // is_default_value() answers "is this at its default", NOT "is this on".
        // Conflating the two is how one concludes a feature is enabled when it
        // is merely untouched.
        println!(
            "{id:<44} enabled={:<5} at_default={:<5} status={:?}  [{category}]",
            defaults.is_feature_enabled(&feature),
            feature.is_default_value(),
            feature.status()
        );
    }
}

fn exit_code(code: gtk4::glib::ExitCode) -> ExitCode {
    if code == gtk4::glib::ExitCode::SUCCESS { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}
