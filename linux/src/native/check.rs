//! `tvmv --self-check`: scripted checks of the native view, driving real GTK
//! widgets. Runs anywhere GTK can open a window; headless under Broadway:
//!
//! ```sh
//! gtk4-broadwayd :7 &
//! GDK_BACKEND=broadway BROADWAY_DISPLAY=:7 tvmv --self-check
//! ```
//!
//! Broadway sends one frame unless a browser is attached, so checks that need
//! fresh layout after an edit only pass on a real display; none here do.

use std::rc::Rc;
use std::time::{Duration, Instant};

use gtk4::prelude::*;
use gtk4::{MovementStep, glib};

use super::document_view::DocumentView;
use super::theme::NativeTheme;

struct Report {
    failures: usize,
}

impl Report {
    fn check(&mut self, name: &str, ok: bool, detail: impl std::fmt::Display) {
        if !ok {
            self.failures += 1;
        }
        println!("  [{}] {name}: {detail}", if ok { "PASS" } else { "FAIL" });
    }

    fn note(&self, name: &str, detail: impl std::fmt::Display) {
        println!("  [NOTE] {name}: {detail}");
    }
}

fn pump() {
    let ctx = glib::MainContext::default();
    while ctx.pending() {
        ctx.iteration(false);
    }
}

/// Pump until nothing is pending for a little while.
fn settle() {
    let ctx = glib::MainContext::default();
    let mut quiet = 0;
    while quiet < 20 {
        if ctx.iteration(false) {
            quiet = 0;
        } else {
            quiet += 1;
            std::thread::sleep(Duration::from_micros(300));
        }
    }
}

/// Pump until `done`, for up to `limit`.
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

fn theme() -> NativeTheme {
    NativeTheme::new("Source Serif 4", "DejaVu Sans Mono", 16.0, 80.0, false, false)
}

fn open(text: &str, editable: bool) -> (Rc<DocumentView>, gtk4::Window) {
    let doc = DocumentView::new(theme());
    doc.load(text.to_string());
    doc.set_editable(editable);
    let window = gtk4::Window::new();
    window.set_default_size(800, 700);
    let scroller = gtk4::ScrolledWindow::new();
    scroller.set_child(Some(&doc.view));
    window.set_child(Some(&scroller));
    window.present();
    settle();
    (doc, window)
}

/// The buffer's text, hidden characters included.
fn buffer_text(doc: &DocumentView) -> String {
    let (s, e) = doc.buffer.bounds();
    doc.buffer.text(&s, &e, true).to_string()
}

fn caret(doc: &DocumentView) -> usize {
    doc.selection().start
}

fn press(doc: &DocumentView, step: MovementStep, count: i32, extend: bool) {
    doc.view.emit_by_name::<()>("move-cursor", &[&step, &count, &extend]);
    pump();
}

/// Type `s` one character at a time, as GTK does for keystrokes.
fn type_text(doc: &DocumentView, s: &str) {
    for c in s.chars() {
        doc.buffer.begin_user_action();
        doc.buffer.insert_interactive_at_cursor(&c.to_string(), true);
        doc.buffer.end_user_action();
        pump();
    }
}

fn inside_hidden(doc: &DocumentView, at: usize) -> bool {
    at > 0 && doc.hidden_at(at - 1) && doc.hidden_at(at)
}

const CARET_TEXT: &str =
    "a **bold** b *it* `code` [link](http://x.y) end\n\n## Heading two\n\n```\nfn main() {}\n```\n\n- item one\n- item two\n";

fn caret_checks(r: &mut Report) {
    println!("\nA. caret and delete around hidden markup");
    let (doc, _window) = open(CARET_TEXT, true);
    let line_end = CARET_TEXT.find('\n').unwrap();

    doc.set_caret(0);
    pump();
    let mut seen = vec![caret(&doc)];
    for _ in 0..80 {
        press(&doc, MovementStep::VisualPositions, 1, false);
        let at = caret(&doc);
        if at >= line_end || seen.last() == Some(&at) {
            seen.push(at);
            break;
        }
        seen.push(at);
    }
    let bad: Vec<_> = seen.iter().filter(|&&o| inside_hidden(&doc, o)).collect();
    r.check("A1 right-arrow never rests inside hidden markup", bad.is_empty(), format!("stops inside: {bad:?}"));
    r.note("A1 presses to cross line 1", format!("{} presses", seen.len() - 1));

    let mut back = vec![caret(&doc)];
    for _ in 0..80 {
        press(&doc, MovementStep::VisualPositions, -1, false);
        let at = caret(&doc);
        if back.last() == Some(&at) {
            break;
        }
        back.push(at);
    }
    let bad: Vec<_> = back.iter().filter(|&&o| inside_hidden(&doc, o)).collect();
    r.check("A1b left-arrow never rests inside hidden markup", bad.is_empty(), format!("stops inside: {bad:?}"));

    doc.set_caret(0);
    let mut words = vec![];
    for _ in 0..10 {
        press(&doc, MovementStep::Words, 1, false);
        words.push(caret(&doc));
    }
    let bad: Vec<_> = words.iter().filter(|&&o| inside_hidden(&doc, o)).collect();
    r.check("A2 word motion never rests inside hidden markup", bad.is_empty(), format!("offsets {words:?}"));

    // Backspace right after the closing ** of bold deletes the visible 'd'.
    let after_bold = CARET_TEXT.find("** b").unwrap() + 2;
    doc.set_caret(after_bold);
    pump();
    doc.view.emit_by_name::<()>("backspace", &[]);
    settle();
    let text = doc.text();
    r.check("A4 backspace after a hidden closer deletes the visible 'd'", text.starts_with("a **bol** b"), format!("{:?}", &text[..14]));
    doc.undo();
    settle();
    r.check("A4b undo restores the text exactly", doc.text() == CARET_TEXT, "");

    // Delete just before the hidden opener of *it* deletes the visible 'i'.
    let before_it = CARET_TEXT.find("*it*").unwrap();
    doc.set_caret(before_it);
    pump();
    doc.view.emit_by_name::<()>("delete-from-cursor", &[&gtk4::DeleteType::Chars, &1i32]);
    settle();
    r.check("A5 delete before a hidden opener deletes the visible 'i'", doc.text().contains(" *t* "), "");
    doc.undo();
    settle();

    let heading = CARET_TEXT.find("Heading").unwrap();
    doc.set_caret(heading + 4);
    press(&doc, MovementStep::DisplayLineEnds, -1, false);
    r.check("A7 Home on a heading lands after '## '", caret(&doc) == heading, format!("caret {}", caret(&doc)));
    doc.set_caret(heading - 3);
    pump();
    r.check("A8 a caret placed before a line prefix snaps after it", caret(&doc) == heading, format!("caret {}", caret(&doc)));

    let fence = CARET_TEXT.find("```\nfn").unwrap();
    doc.set_caret(heading);
    let mut lines = vec![];
    for _ in 0..4 {
        press(&doc, MovementStep::DisplayLines, 1, false);
        lines.push(caret(&doc));
    }
    let on_fence = lines.iter().any(|&o| (fence..fence + 4).contains(&o) && o != fence + 4);
    r.check("A6 down-arrow passes the collapsed fence lines", !on_fence, format!("offsets {lines:?}"));

    r.check("A9 loading leaves nothing to undo", !DocumentView::new(theme()).can_undo(), "");

    let end = doc.text().len();
    doc.set_caret(end);
    type_text(&doc, "\n*new*");
    let end = doc.text().len();
    let italic = doc.has_tag_at(end - 2, "emphasis");
    let hidden = doc.hidden_at(end - 1);
    r.check("A10 typing *new* turns italic and hides the stars", italic && hidden, format!("italic={italic} hidden={hidden}"));
}

fn soft_break_checks(r: &mut Report) {
    println!("\nB. soft line breaks reflow");
    let text = "one\ntwo\nthree\n\nnext\n";
    let (doc, _window) = open(text, true);
    r.check("B1 the buffer shows soft breaks as spaces", buffer_text(&doc) == "one two three\n\nnext\n", format!("{:?}", buffer_text(&doc)));
    r.check("B2 the source keeps its newlines", doc.text() == text, "");
    doc.set_caret(3);
    type_text(&doc, "\\");
    r.check("B3 a backslash makes a hard break: the newline shows", buffer_text(&doc).starts_with("one\\\ntwo three"), format!("{:?}", buffer_text(&doc)));
    doc.undo();
    settle();
    r.check("B4 undo brings the soft break back", buffer_text(&doc) == "one two three\n\nnext\n" && doc.text() == text, format!("{:?}", buffer_text(&doc)));
    // Deleting the space a soft break shows joins the lines in the source.
    doc.set_caret(3);
    doc.view.emit_by_name::<()>("delete-from-cursor", &[&gtk4::DeleteType::Chars, &1i32]);
    settle();
    r.check("B5 deleting a soft break's space joins the source lines", doc.text() == "onetwo\nthree\n\nnext\n", format!("{:?}", doc.text()));
}

fn editing_checks(r: &mut Report) {
    println!("\nC. editing, undo, lists, tasks, clipboard, reveal");
    let (doc, _window) = open("Start.\n", true);
    doc.set_caret(6);
    type_text(&doc, " abc def");
    doc.undo();
    settle();
    r.check("C1 undo takes back the last word", doc.text() == "Start. abc \n", format!("{:?}", doc.text()));
    doc.undo();
    settle();
    r.check("C2 a second undo takes back the first", doc.text() == "Start.\n", format!("{:?}", doc.text()));
    doc.redo();
    doc.redo();
    settle();
    r.check("C3 redo replays both", doc.text() == "Start. abc def\n", format!("{:?}", doc.text()));

    let (doc, _window) = open("- one\n- [ ] task\n\n1. first\n", true);
    doc.set_caret(5);
    doc.insert_newline();
    settle();
    r.check("C4 Return continues a list", doc.text() == "- one\n- \n- [ ] task\n\n1. first\n", format!("{:?}", doc.text()));
    doc.insert_newline();
    settle();
    r.check("C5 Return on an empty item ends it", doc.text() == "- one\n\n- [ ] task\n\n1. first\n", format!("{:?}", doc.text()));
    let end = doc.text().len() - 1;
    doc.set_caret(end);
    doc.insert_newline();
    settle();
    r.check("C6 an ordered list counts on", doc.text().ends_with("1. first\n2. \n"), format!("{:?}", doc.text()));

    let (doc, _window) = open("- [ ] task\n", false);
    doc.toggle_task(0);
    settle();
    r.check("C7 a checkbox toggles while read-only", doc.text() == "- [x] task\n", format!("{:?}", doc.text()));
    doc.undo();
    settle();
    r.check("C8 and the toggle undoes", doc.text() == "- [ ] task\n", "");

    let text = "a **bold** word\n\n```\ncode\n```\n";
    let (doc, _window) = open(text, true);
    let bold = text.find("bold").unwrap();
    let copied = doc.copy_range(bold..bold + 4);
    r.check("C9 copying a bold word copies its markup", &text[copied.clone()] == "**bold**", format!("{:?}", &text[copied]));
    doc.set_caret(bold + 1);
    pump();
    doc.reveal(true);
    r.check("C10 reveal shows the span's markup", !doc.hidden_at(bold - 1), "");
    doc.reveal(false);
    r.check("C11 and Esc hides it again", doc.hidden_at(bold - 1), "");
    doc.toggle_show_all_markup();
    settle();
    let any_hidden = (0..text.len()).any(|b| doc.hidden_at(b));
    r.check("C12 Show Markdown hides nothing", !any_hidden, "");
    doc.toggle_show_all_markup();
    settle();
    let word = text.find("word").unwrap();
    doc.select(word..word + 4);
    doc.wrap_selection("*");
    settle();
    r.check("C13 Ctrl+I wraps the selection", doc.text().contains("*word*"), format!("{:?}", doc.text()));
    doc.wrap_selection("*");
    settle();
    r.check("C14 and unwraps it", doc.text() == text, format!("{:?}", doc.text()));
}

fn big_document(target: usize) -> String {
    let mut s = String::new();
    let mut n = 0;
    while s.len() < target {
        n += 1;
        s.push_str(&format!(
            "## Section {n}\n\nSome *emphasis* and **strong** text with `code` and a [link](https://example.com/{n}).\n\
             A soft-wrapped second line ~~gone~~ continues the paragraph.\n\n\
             - item *one*\n- item **two** with `x`\n\n```rust\nfn main() {{ println!(\"{n}\"); }}\n```\n\n"
        ));
    }
    s
}

fn perf_checks(r: &mut Report, size: usize) {
    println!("\nD. performance at {} KB", size / 1024);
    let text = big_document(size);
    let start = Instant::now();
    let doc = DocumentView::new(theme());
    doc.load(text.clone());
    let window = gtk4::Window::new();
    window.set_default_size(800, 700);
    let scroller = gtk4::ScrolledWindow::new();
    scroller.set_child(Some(&doc.view));
    window.set_child(Some(&scroller));
    window.present();
    let shown = start.elapsed();
    let first_styled = doc.has_tag_at(0, "h2") || doc.hidden_at(0);
    let loaded = until(Duration::from_secs(20), || doc.is_loaded());
    let parsed = start.elapsed();
    let styled = until(Duration::from_secs(120), || !doc.is_styling());
    let all_styled = start.elapsed();
    settle();
    r.check(
        "D1 opens, parses and styles",
        loaded && styled,
        format!("shown {shown:?}, parsed {parsed:?}, styled {all_styled:?}, idle {:?}", start.elapsed()),
    );
    r.check("D1b the first screen is styled when it is first shown", first_styled && shown < Duration::from_millis(50), format!("{shown:?}"));
    doc.set_editable(true);
    let mid = doc.text().len() / 2;
    let mid = doc.text()[mid..].find("Some").map_or(mid, |i| mid + i);
    doc.set_caret(mid);
    let mut keystrokes = vec![];
    let mut applies = vec![];
    for i in 0..20 {
        let t = Instant::now();
        type_text(&doc, if i % 2 == 0 { "*" } else { "x" });
        keystrokes.push(t.elapsed());
        let before = doc.text().len();
        until(Duration::from_secs(5), || doc.last_apply() > Duration::ZERO && doc.text().len() == before);
        settle();
        applies.push(doc.last_apply());
    }
    keystrokes.sort();
    applies.sort();
    let (key, apply) = (keystrokes[10], applies[10]);
    r.check("D2 main-thread work per keystroke under 16 ms", key + apply < Duration::from_millis(16), format!("keystroke {key:?} + installing the parse {apply:?}"));
    window.close();
}

/// Where GTK says the first visible character after hidden text is, with
/// one property at a time (diagnostic: `TVMV_TRACE_HIDDEN=1 tvmv --self-check`).
fn trace_hidden() {
    for variant in ["hidden", "hidden+scale", "hidden+line-height", "hidden+css-line-height", "hidden+margin"] {
        let view = gtk4::TextView::new();
        let buffer = view.buffer();
        buffer.set_text("## Text here\nplain line\n");
        let hidden = gtk4::TextTag::builder().invisible(true).build();
        let extra = gtk4::TextTag::new(None);
        buffer.tag_table().add(&extra);
        buffer.tag_table().add(&hidden);
        match variant {
            "hidden+scale" => extra.set_scale(1.5),
            "hidden+line-height" => extra.set_line_height(1.7),
            "hidden+margin" => extra.set_left_margin(40),
            "hidden+css-line-height" => {
                let provider = gtk4::CssProvider::new();
                provider.load_from_string("textview.probe { line-height: 1.7; }");
                gtk4::style_context_add_provider_for_display(&gtk4::gdk::Display::default().unwrap(), &provider, 800);
                view.add_css_class("probe");
            }
            _ => {}
        }
        let line_end = buffer.iter_at_offset(12);
        buffer.apply_tag(&extra, &buffer.start_iter(), &line_end);
        buffer.apply_tag(&hidden, &buffer.start_iter(), &buffer.iter_at_offset(3));
        let window = gtk4::Window::new();
        window.set_default_size(400, 200);
        window.set_child(Some(&view));
        window.present();
        settle();
        let start = view.iter_location(&buffer.start_iter());
        let t = view.iter_location(&buffer.iter_at_offset(3));
        let e = view.iter_location(&buffer.iter_at_offset(4));
        let (strong, _) = view.cursor_locations(Some(&buffer.iter_at_offset(3)));
        println!("{variant:24} line start x={:3}  'T' x={:3}  'e' x={:3}  caret x={:3}", start.x(), t.x(), e.x(), strong.x());
        window.close();
    }
    // Mid-line hidden runs: "a `code` b" with the backticks hidden.
    let view = gtk4::TextView::new();
    let buffer = view.buffer();
    buffer.set_text("aa `code` bb\n");
    let hidden = gtk4::TextTag::builder().invisible(true).build();
    buffer.tag_table().add(&hidden);
    buffer.apply_tag(&hidden, &buffer.iter_at_offset(3), &buffer.iter_at_offset(4));
    buffer.apply_tag(&hidden, &buffer.iter_at_offset(8), &buffer.iter_at_offset(9));
    let window = gtk4::Window::new();
    window.set_default_size(400, 200);
    window.set_child(Some(&view));
    window.present();
    settle();
    for offset in 0..13 {
        let iter = buffer.iter_at_offset(offset);
        let (strong, weak) = view.cursor_locations(Some(&iter));
        println!("offset {offset:2} {:?}: cursor x={:3} y={:3} (weak x={:3})  iter_location x={:3}", iter.char(), strong.x(), strong.y(), weak.x(), view.iter_location(&iter).x());
    }
}

/// Where styling a large document spends its time: `TVMV_TRACE_STYLING=1
/// tvmv --self-check`, and with `TVMV_TRACE_PLAIN=1` the unstyled baseline.
fn trace_styling() {
    let text = big_document(5 * 1024 * 1024);
    let doc = DocumentView::new(theme());
    doc.load(text.clone());
    let window = gtk4::Window::new();
    window.set_default_size(800, 700);
    let scroller = gtk4::ScrolledWindow::new();
    scroller.set_child(Some(&doc.view));
    window.set_child(Some(&scroller));
    window.present();
    until(Duration::from_secs(20), || doc.is_loaded());
    doc.stop_styling();
    if std::env::var_os("TVMV_TRACE_PLAIN").is_some() {
        let t = Instant::now();
        settle();
        println!("plain: GTK idle work {:?}", t.elapsed());
        return;
    }
    for at in [0usize, 1 << 20, 2 << 20, 4 << 20, 5 << 20] {
        let at = at.min(text.len() - 40_000);
        let t = Instant::now();
        doc.restyle(at..at + 32 * 1024);
        println!("restyle 32 KB at {:>5} KB: {:?}", at / 1024, t.elapsed());
    }
    let t = Instant::now();
    doc.restyle(0..text.len());
    println!("restyle everything at once: {:?}", t.elapsed());
    let t = Instant::now();
    settle();
    println!("then GTK idle work: {:?}", t.elapsed());
}

/// `tvmv --native-shot IN.md OUT.png [WIDTHxHEIGHT]`: render the native
/// view of a file to a PNG, offscreen (for checking the look headless).
pub fn screenshot(input: &std::path::Path, output: &str, size: (i32, i32)) -> glib::ExitCode {
    if gtk4::init().is_err() {
        eprintln!("tvmv: --native-shot needs a display (GDK_BACKEND=broadway works headless)");
        return glib::ExitCode::FAILURE;
    }
    let text = match std::fs::read_to_string(input) {
        Ok(text) => text,
        Err(e) => {
            eprintln!("tvmv: {}: {e}", input.display());
            return glib::ExitCode::FAILURE;
        }
    };
    let dark = std::env::var_os("TVMV_DARK").is_some();
    let doc = DocumentView::new(NativeTheme::new("Source Serif 4", "DejaVu Sans Mono", 16.0, 80.0, false, dark));
    doc.load(text);
    let window = gtk4::Window::new();
    window.set_default_size(size.0, size.1);
    let scroller = gtk4::ScrolledWindow::new();
    scroller.set_child(Some(&doc.view));
    window.set_child(Some(&scroller));
    let painted = Rc::new(std::cell::Cell::new(0));
    {
        let painted = Rc::clone(&painted);
        window.connect_realize(move |w| {
            let painted = Rc::clone(&painted);
            if let Some(clock) = w.frame_clock() {
                clock.connect_after_paint(move |_| painted.set(painted.get() + 1));
            }
        });
    }
    window.present();
    until(Duration::from_secs(30), || doc.is_loaded() && !doc.is_styling());
    settle();
    let frames = painted.get();
    doc.view.queue_draw();
    until(Duration::from_secs(5), || painted.get() > frames);
    if std::env::var_os("TVMV_TRACE_ITEMS").is_some() {
        let model = doc.model.borrow();
        for item in model.prepared.layout.list_items.iter().take(6) {
            let offset = model.source.to_buffer(item.marker.end);
            let iter = doc.buffer.iter_at_offset(offset);
            let rect = doc.view.iter_location(&iter);
            println!("item {:?} -> buffer {offset} char {:?} rect x={} y={}", &model.source.text()[item.marker.clone()], iter.char(), rect.x(), rect.y());
            let mut line = iter;
            line.set_line_offset(0);
            let start = doc.view.iter_location(&line);
            let tags: Vec<String> = iter.tags().iter().map(|t| format!("{:?} lm={} ind={}", t.name(), t.left_margin(), t.indent())).collect();
            println!("   line start rect x={} ; tags at char: {tags:?}", start.x());
        }
        let text = model.source.text();
        let at = text.find("Text\n").unwrap();
        let rect = doc.view.iter_location(&doc.buffer.iter_at_offset(model.source.to_buffer(at)));
        println!("heading 'T' x={} y={}; view left margin {}", rect.x(), rect.y(), doc.view.left_margin());
    }
    let paintable = gtk4::WidgetPaintable::new(Some(&window));
    let snapshot = gtk4::Snapshot::new();
    paintable.snapshot(&snapshot, window.width() as f64, window.height() as f64);
    let (Some(node), Some(renderer)) = (snapshot.to_node(), window.renderer()) else {
        eprintln!(
            "tvmv: nothing to render (window {}x{}, mapped {}, renderer {})",
            window.width(),
            window.height(),
            window.is_mapped(),
            window.renderer().is_some()
        );
        return glib::ExitCode::FAILURE;
    };
    match renderer.render_texture(&node, None).save_to_png(output) {
        Ok(()) => glib::ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("tvmv: {output}: {e}");
            glib::ExitCode::FAILURE
        }
    }
}

pub fn run() -> glib::ExitCode {
    if std::env::var_os("TVMV_TRACE_HIDDEN").is_some() {
        let _ = gtk4::init();
        trace_hidden();
        return glib::ExitCode::SUCCESS;
    }
    if std::env::var_os("TVMV_TRACE_STYLING").is_some() {
        let _ = gtk4::init();
        trace_styling();
        return glib::ExitCode::SUCCESS;
    }
    if gtk4::init().is_err() {
        eprintln!("tvmv: --self-check needs a display (GDK_BACKEND=broadway works headless)");
        return glib::ExitCode::FAILURE;
    }
    let mut r = Report { failures: 0 };
    caret_checks(&mut r);
    soft_break_checks(&mut r);
    editing_checks(&mut r);
    for size in [64 * 1024, 1024 * 1024, 5 * 1024 * 1024] {
        perf_checks(&mut r, size);
    }
    println!("\nfailures: {}", r.failures);
    glib::ExitCode::from(r.failures.min(255) as u8)
}
