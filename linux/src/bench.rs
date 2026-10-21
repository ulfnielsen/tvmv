//! `tvmv --bench FILE [--runs N]`: open the same file in the WebKit window and
//! in the native view, each in a fresh process, and print the two side by side.
//!
//! Needs a real display: WebKit under Broadway or Xvfb is not representative.
//! A locked or blanked screen paints no frames, so keep it awake for the run:
//! `gnome-session-inhibit --inhibit idle tvmv --bench FILE`.
//!
//! What is measured, per process:
//! - **open**: from the start of the run to the document on screen. For WebKit
//!   that is the page's `renderComplete`; for the native view, the first frame
//!   painted (its first screen is styled before that frame).
//! - **all styled**: the native view styles a large document lazily after the
//!   first screen; this is when it is done. WebKit has no such phase.
//! - **open, warm**: a second window on the same file in the same process. The
//!   old app is single-instance, so this is what every open after the first
//!   costs there.
//! - **change**: WebKit re-renders the whole preview after an edit, once the
//!   debounce (printed beside it) has passed; this times the render itself.
//!   The native view restyles in place: a keystroke until its parse is
//!   installed, and the main thread's share of that.
//! - **scroll**: frames actually painted while scrolling 24 px a frame for 5 s.
//! - **memory**: proportional set size of the process and every process it
//!   started (WebKit's web and network processes), and the peak RSS of the
//!   process itself.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::rc::Rc;
use std::time::{Duration, Instant};

use gtk4::prelude::*;
use gtk4::{gio, glib};

use crate::native::document_view::DocumentView;
use crate::native::theme::NativeTheme;
use crate::settings::Settings;

const SCROLL_SECONDS: u64 = 5;
const KEYSTROKES: usize = 11;
const RERENDERS: usize = 3;

/// The parent: run each variant in its own process and print the comparison.
pub fn run(path: &Path, runs: usize) -> ExitCode {
    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(e) => {
            eprintln!("tvmv: {e}");
            return ExitCode::FAILURE;
        }
    };
    let size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    println!("{} ({} KB), {runs} run(s) each, median shown\n", path.display(), size / 1024);
    let mut results: HashMap<&str, Vec<HashMap<String, f64>>> = HashMap::new();
    for run in 0..runs {
        for kind in ["webkit", "native"] {
            eprintln!("run {}/{runs}: {kind}…", run + 1);
            let output = Command::new(&exe).args(["--bench-run", kind]).arg(path).output();
            let output = match output {
                Ok(output) => output,
                Err(e) => {
                    eprintln!("tvmv: {e}");
                    return ExitCode::FAILURE;
                }
            };
            let stdout = String::from_utf8_lossy(&output.stdout);
            let Some(line) = stdout.lines().find_map(|l| l.strip_prefix("BENCH ")) else {
                eprintln!("tvmv: the {kind} run reported nothing:\n{}", String::from_utf8_lossy(&output.stderr));
                return ExitCode::FAILURE;
            };
            let values = line
                .split_whitespace()
                .filter_map(|kv| {
                    let (k, v) = kv.split_once('=')?;
                    Some((k.to_string(), v.parse().ok()?))
                })
                .collect();
            results.entry(kind).or_default().push(values);
        }
    }
    let median = |kind: &str, key: &str| -> Option<f64> {
        let mut v: Vec<f64> = results.get(kind)?.iter().filter_map(|r| r.get(key).copied()).collect();
        if v.is_empty() {
            return None;
        }
        v.sort_by(|a, b| a.total_cmp(b));
        Some(v[v.len() / 2])
    };
    let rows: [(&str, &str, &str, &str); 11] = [
        ("open", "open_ms", "open_ms", "ms"),
        ("all styled", "", "styled_ms", "ms"),
        ("open, warm", "warm_ms", "warm_ms", "ms"),
        ("change: debounce", "debounce_ms", "", "ms"),
        ("change: render / restyle", "rerender_ms", "key_ms", "ms"),
        ("change: main thread", "rerender_main_ms", "key_main_ms", "ms"),
        ("scroll: fps", "fps", "fps", ""),
        ("scroll: p95 frame", "p95_ms", "p95_ms", "ms"),
        ("scroll: worst frame", "worst_ms", "worst_ms", "ms"),
        ("memory, all processes", "pss_mb", "pss_mb", "MB"),
        ("peak RSS, main process", "hwm_mb", "hwm_mb", "MB"),
    ];
    println!("{:<26} {:>12} {:>12}", "", "WebKit", "native");
    for (label, old, new, unit) in rows {
        let cell = |kind: &str, key: &str| match (key.is_empty(), median(kind, key)) {
            (true, _) => "—".to_string(),
            (false, Some(v)) => format!("{v:.1}{}{unit}", if unit.is_empty() { "" } else { " " }),
            (false, None) => "n/a".to_string(),
        };
        println!("{label:<26} {:>12} {:>12}", cell("webkit", old), cell("native", new));
    }
    if let Some(procs) = median("webkit", "procs") {
        println!("\nWebKit memory is summed over {procs:.0} processes.");
    }
    ExitCode::SUCCESS
}

/// The child: one variant, reporting a single `BENCH key=value …` line.
pub fn run_one(kind: &str, path: &Path) -> ExitCode {
    let start = Instant::now();
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) => {
            eprintln!("tvmv: {}: {e}", path.display());
            return ExitCode::FAILURE;
        }
    };
    match kind {
        "webkit" => webkit(path.to_path_buf(), text, start),
        "native" => native(text, start),
        _ => {
            eprintln!("tvmv: --bench-run takes webkit or native");
            ExitCode::FAILURE
        }
    }
}

type Report = Rc<RefCell<Vec<(String, f64)>>>;

fn report(values: &Report) {
    let (pss, procs) = tree_pss_kb();
    let mut v = values.borrow_mut();
    v.push(("pss_mb".into(), pss as f64 / 1024.0));
    v.push(("procs".into(), procs as f64));
    v.push(("hwm_mb".into(), own_hwm_kb() as f64 / 1024.0));
    let line: Vec<String> = v.iter().map(|(k, x)| format!("{k}={x:.3}")).collect();
    println!("BENCH {}", line.join(" "));
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.total_cmp(b));
    v[v.len() / 2]
}

// --- WebKit ------------------------------------------------------------

fn webkit(path: PathBuf, text: String, start: Instant) -> ExitCode {
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
    let app = gtk4::Application::builder()
        .application_id("dk.dyregod.tvmv.bench")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    let values: Report = Rc::default();
    let text = Rc::new(text);
    app.connect_activate(move |app| {
        let window_slot: Rc<RefCell<Option<gtk4::ApplicationWindow>>> = Rc::default();
        // 0 is the first render; 1..=RERENDERS are timed re-renders.
        let phase = Rc::new(Cell::new(0usize));
        let mark = Rc::new(Cell::new(start));
        let rerenders: Rc<RefCell<Vec<f64>>> = Rc::default();
        let mains: Rc<RefCell<Vec<f64>>> = Rc::default();
        let done: crate::window::OnRenderComplete = {
            let (app, values, text, slot) = (app.clone(), Rc::clone(&values), Rc::clone(&text), Rc::clone(&window_slot));
            let path = path.clone();
            Box::new(move |preview| {
                let n = phase.get();
                if n > RERENDERS {
                    return;
                }
                phase.set(n + 1);
                if n == 0 {
                    values.borrow_mut().push(("open_ms".into(), ms(start.elapsed())));
                    let debounce = crate::window::render_debounce(&text);
                    values.borrow_mut().push(("debounce_ms".into(), ms(debounce)));
                } else {
                    rerenders.borrow_mut().push(ms(mark.get().elapsed()));
                }
                if n < RERENDERS {
                    // What the window does once the debounce after an edit has passed.
                    let t = Instant::now();
                    mark.set(t);
                    let html = crate::render::render_html(&text, true);
                    preview.render(&html, &format!("{}://doc/", crate::assets::SCHEME));
                    mains.borrow_mut().push(ms(t.elapsed()));
                    return;
                }
                values.borrow_mut().push(("rerender_ms".into(), median(rerenders.borrow().clone())));
                values.borrow_mut().push(("rerender_main_ms".into(), median(mains.borrow().clone())));
                preview.eval(SCROLL_JS);
                let Some(window) = slot.borrow().clone() else { return };
                let (app, values, path) = (app.clone(), Rc::clone(&values), path.clone());
                let measured: gtk4::Window = window.clone().upcast();
                measure_frames(&measured, Rc::clone(&values), move || {
                    // A second window in the same process: the warm open.
                    window.close();
                    let warm = Instant::now();
                    let fired = Rc::new(Cell::new(false));
                    let (values, quit) = (Rc::clone(&values), app.clone());
                    let done: crate::window::OnRenderComplete = Box::new(move |_| {
                        if fired.replace(true) {
                            return;
                        }
                        values.borrow_mut().push(("warm_ms".into(), ms(warm.elapsed())));
                        report(&values);
                        quit.quit();
                    });
                    if crate::app::open_web_window(&app, &path, Some(done)).is_none() {
                        app.quit();
                    }
                });
            })
        };
        match crate::app::open_web_window(app, &path, Some(done)) {
            Some(window) => *window_slot.borrow_mut() = Some(window),
            None => app.quit(),
        }
    });
    let code = app.run_with_args::<&str>(&[]);
    if code == glib::ExitCode::SUCCESS { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}

// --- native ------------------------------------------------------------

fn native(text: String, start: Instant) -> ExitCode {
    if gtk4::init().is_err() {
        eprintln!("tvmv: no display");
        return ExitCode::FAILURE;
    }
    let values: Report = Rc::default();
    let (doc, window, scroller) = native_window(&text);
    if std::env::var_os("TVMV_BENCH_TRACE").is_some() {
        eprintln!("{:>9.1} ms  window presented", ms(start.elapsed()));
        trace_frames(&window, start);
        let last = Cell::new(Instant::now());
        glib::timeout_add_local(Duration::from_millis(5), move || {
            let gap = last.replace(Instant::now()).elapsed();
            if gap > Duration::from_millis(30) {
                eprintln!("{:>9.1} ms  main loop blocked {:.0} ms", ms(start.elapsed()), ms(gap));
            }
            glib::ControlFlow::Continue
        });
    }
    let painted = first_paint(&window);
    until(Duration::from_secs(30), || painted.get().is_some());
    let Some(first) = painted.get() else {
        eprintln!("tvmv: no frame painted in 30 s — is the screen locked or blanked?");
        return ExitCode::FAILURE;
    };
    values.borrow_mut().push(("open_ms".into(), ms(first - start)));
    until(Duration::from_secs(300), || doc.is_loaded() && !doc.is_styling());
    values.borrow_mut().push(("styled_ms".into(), ms(start.elapsed())));
    settle(Duration::from_millis(300));

    // Keystrokes mid-document, each until its parse has been installed.
    doc.set_editable(true);
    let all = doc.text();
    let mid = all.len() / 2;
    let mid = all[mid..].find(char::is_whitespace).map_or(mid, |i| mid + i);
    doc.set_caret(mid);
    let (mut walls, mut mains) = (vec![], vec![]);
    for _ in 0..KEYSTROKES {
        let applied = doc.parses_applied();
        let t = Instant::now();
        doc.buffer.begin_user_action();
        doc.buffer.insert_interactive_at_cursor("x", true);
        doc.buffer.end_user_action();
        let key = t.elapsed();
        until(Duration::from_secs(10), || doc.parses_applied() > applied);
        walls.push(ms(t.elapsed()));
        mains.push(ms(key + doc.last_apply()));
        settle(Duration::from_millis(50));
    }
    values.borrow_mut().push(("key_ms".into(), median(walls)));
    values.borrow_mut().push(("key_main_ms".into(), median(mains)));
    doc.set_editable(false);

    // Scroll 24 px a frame, bouncing at the ends.
    let adj = scroller.vadjustment();
    let step = Rc::new(Cell::new(24.0));
    let tick = {
        let step = Rc::clone(&step);
        scroller.add_tick_callback(move |_, _| {
            let max = adj.upper() - adj.page_size();
            let next = adj.value() + step.get();
            if next >= max || next <= 0.0 {
                step.set(-step.get());
            }
            adj.set_value(next.clamp(0.0, max));
            glib::ControlFlow::Continue
        })
    };
    let finished = Rc::new(Cell::new(false));
    let flag = Rc::clone(&finished);
    measure_frames(window.upcast_ref(), Rc::clone(&values), move || flag.set(true));
    until(Duration::from_secs(SCROLL_SECONDS + 10), || finished.get());
    tick.remove();
    window.close();

    // A second view on the same text in the same process: the warm open.
    let warm = Instant::now();
    let (_doc2, window2, _) = native_window(&text);
    let painted = first_paint(&window2);
    until(Duration::from_secs(30), || painted.get().is_some());
    values.borrow_mut().push(("warm_ms".into(), painted.get().map_or(-1.0, |t| ms(t - warm))));
    report(&values);
    window2.close();
    ExitCode::SUCCESS
}

fn native_window(text: &str) -> (Rc<DocumentView>, gtk4::Window, gtk4::ScrolledWindow) {
    let (settings, _) = Settings::load();
    let doc = DocumentView::new(NativeTheme::from_settings(&settings, crate::appearance::prefers_dark()));
    doc.load(text.to_string());
    let window = gtk4::Window::builder().default_width(900).default_height(1000).build();
    let scroller = gtk4::ScrolledWindow::new();
    scroller.set_hscrollbar_policy(gtk4::PolicyType::Never);
    scroller.set_child(Some(&doc.view));
    window.set_child(Some(&scroller));
    window.present();
    (doc, window, scroller)
}

/// When the window's first frame is painted.
fn first_paint(window: &gtk4::Window) -> Rc<Cell<Option<Instant>>> {
    let at: Rc<Cell<Option<Instant>>> = Rc::default();
    let slot = Rc::clone(&at);
    let window = window.clone();
    // The frame clock exists once the window is realized. High priority: the
    // view styles large documents at idle priority, and this must not wait
    // for that.
    glib::idle_add_local_full(glib::Priority::HIGH, move || {
        let Some(clock) = window.frame_clock() else { return glib::ControlFlow::Continue };
        let slot = Rc::clone(&slot);
        let handler: Rc<RefCell<Option<glib::SignalHandlerId>>> = Rc::default();
        let handler_ref = Rc::clone(&handler);
        *handler.borrow_mut() = Some(clock.connect_after_paint(move |clock| {
            if slot.get().is_none() {
                slot.set(Some(Instant::now()));
                if let Some(id) = handler_ref.borrow_mut().take() {
                    clock.disconnect(id);
                }
            }
        }));
        glib::ControlFlow::Break
    });
    at
}

/// Print each frame's phases (diagnostic: `TVMV_BENCH_TRACE=1`).
fn trace_frames(window: &gtk4::Window, start: Instant) {
    let window = window.clone();
    glib::idle_add_local_full(glib::Priority::HIGH, move || {
        let Some(clock) = window.frame_clock() else { return glib::ControlFlow::Continue };
        let mark = Rc::new(Cell::new(start));
        for (name, phase) in [("update", 0), ("layout", 1), ("paint", 2), ("after", 3)] {
            let mark = Rc::clone(&mark);
            let f = move |_: &gtk4::gdk::FrameClock| {
                let now = Instant::now();
                eprintln!("{:>9.1} ms  {name:<6} +{:.1} ms", ms(now - start), ms(now - mark.get()));
                mark.set(now);
            };
            match phase {
                0 => clock.connect_update(f),
                1 => clock.connect_layout(f),
                2 => clock.connect_paint(f),
                _ => clock.connect_after_paint(f),
            };
        }
        glib::ControlFlow::Break
    });
}

fn until(limit: Duration, done: impl Fn() -> bool) -> bool {
    let start = Instant::now();
    let ctx = glib::MainContext::default();
    while !done() {
        if start.elapsed() > limit {
            return false;
        }
        if !ctx.iteration(false) {
            std::thread::sleep(Duration::from_micros(200));
        }
    }
    true
}

fn settle(d: Duration) {
    let start = Instant::now();
    until(d, || start.elapsed() >= d);
}

// --- shared ------------------------------------------------------------

/// Count frames the window actually paints for `SCROLL_SECONDS`, record
/// fps / p95 / worst, then call `then`. See `frame_bench` in main.rs for why
/// `after-paint` and not `requestAnimationFrame`.
fn measure_frames(window: &gtk4::Window, values: Report, then: impl FnOnce() + 'static) {
    let Some(clock) = window.frame_clock() else {
        then();
        return;
    };
    let stamps: Rc<RefCell<Vec<i64>>> = Rc::default();
    let recorder = Rc::clone(&stamps);
    let handler = clock.connect_after_paint(move |clock| recorder.borrow_mut().push(clock.frame_time()));
    clock.begin_updating();
    glib::timeout_add_local_once(Duration::from_secs(SCROLL_SECONDS), move || {
        clock.end_updating();
        clock.disconnect(handler);
        let stamps = stamps.borrow();
        let mut gaps: Vec<f64> = stamps.windows(2).map(|w| (w[1] - w[0]) as f64 / 1000.0).collect();
        if gaps.len() >= 4 {
            let span: f64 = gaps.iter().sum();
            gaps.sort_by(|a, b| a.total_cmp(b));
            let mut v = values.borrow_mut();
            v.push(("fps".into(), gaps.len() as f64 / (span / 1000.0)));
            v.push(("p95_ms".into(), gaps[gaps.len() * 95 / 100]));
            v.push(("worst_ms".into(), gaps[gaps.len() - 1]));
        }
        then();
    });
}

/// Proportional set size of this process and all its descendants, in KB,
/// and how many processes that is.
fn tree_pss_kb() -> (u64, usize) {
    let mut parent: HashMap<u32, u32> = HashMap::new();
    if let Ok(dir) = std::fs::read_dir("/proc") {
        for entry in dir.flatten() {
            let Some(pid) = entry.file_name().to_str().and_then(|s| s.parse::<u32>().ok()) else { continue };
            let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else { continue };
            // The command name is parenthesised and may contain spaces.
            let Some(rest) = stat.rfind(')').map(|i| &stat[i + 1..]) else { continue };
            if let Some(ppid) = rest.split_whitespace().nth(1).and_then(|s| s.parse().ok()) {
                parent.insert(pid, ppid);
            }
        }
    }
    let me = std::process::id();
    let in_tree = |mut pid: u32| loop {
        if pid == me {
            return true;
        }
        match parent.get(&pid) {
            Some(&p) if p != 0 && p != pid => pid = p,
            _ => return false,
        }
    };
    let pids: Vec<u32> = parent.keys().copied().filter(|&p| in_tree(p)).collect();
    let total = pids
        .iter()
        .filter_map(|pid| std::fs::read_to_string(format!("/proc/{pid}/smaps_rollup")).ok())
        .filter_map(|s| field_kb(&s, "Pss:"))
        .sum();
    (total, pids.len())
}

fn own_hwm_kb() -> u64 {
    std::fs::read_to_string("/proc/self/status").ok().and_then(|s| field_kb(&s, "VmHWM:")).unwrap_or(0)
}

fn field_kb(text: &str, name: &str) -> Option<u64> {
    text.lines().find_map(|l| l.strip_prefix(name)).and_then(|v| v.split_whitespace().next()?.parse().ok())
}
