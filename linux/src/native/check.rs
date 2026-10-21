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

fn reader_checks(r: &mut Report) {
    println!("\nE. reader");
    let text = big_document(40 * 1024);
    let (doc, window) = open(&text, false);
    let headings = doc.headings();
    let items = crate::reader::outline(&headings);
    r.check(
        "E1 the outline lists the headings with web slugs",
        items.len() > 100 && items[0].anchor == "section-1" && items[41].anchor == "section-42",
        format!("{} items, first {:?}", items.len(), items.first().map(|i| &i.anchor)),
    );
    let target = &headings[60];
    let t = Instant::now();
    doc.scroll_to_offset(target.range.start);
    let at_top = |doc: &DocumentView| {
        let top = doc.top_offset();
        top <= target.range.start && target.range.start - top < 40
    };
    let landed = until(Duration::from_secs(2), || at_top(&doc));
    r.check(
        "E2 scrolling to a heading puts it at the top",
        landed,
        format!("heading at {}, top {} after {:?}", target.range.start, doc.top_offset(), t.elapsed()),
    );
    doc.scroll_to_fraction(0.5);
    settle();
    let f = doc.scroll_fraction();
    r.check("E3 a fraction scrolls to that fraction", (f - 0.5).abs() < 0.02, format!("{f:.3}"));

    let matches = crate::reader::find_matches(&doc.text(), "emphasis");
    doc.set_find(matches.clone(), Some(3));
    let tagged = |doc: &DocumentView| {
        doc.has_tag_at(matches[0].start + 1, "find")
            && doc.has_tag_at(matches[3].start + 1, "find-current")
            && !doc.has_tag_at(matches[3].start + 1, "find")
    };
    let before = tagged(&doc);
    doc.restyle(0..doc.text().len());
    r.check("E4 find's highlights survive restyling", before && tagged(&doc), format!("{} matches", matches.len()));
    doc.show_match(matches[50].clone());
    let shown = until(Duration::from_secs(2), || doc.top_offset() < matches[50].start && doc.top_offset() + 2000 > matches[50].start)
        && doc.selection() == matches[50];
    doc.set_find(Vec::new(), None);
    r.check(
        "E5 showing a match selects it and scrolls to it; clearing removes the highlights",
        shown && !doc.has_tag_at(matches[0].start + 1, "find"),
        format!("selection {:?}, match {:?}", doc.selection(), matches[50]),
    );
    window.close();

    // A large document: the offset lands once the whole text is in.
    let text = big_document(1024 * 1024);
    let (doc, window) = open(&text, false);
    until(Duration::from_secs(20), || doc.is_loaded());
    let at = text[text.len() * 2 / 3..].find("## ").map(|i| text.len() * 2 / 3 + i).unwrap_or(0);
    doc.scroll_to_offset(at);
    until(Duration::from_secs(10), || doc.top_offset().abs_diff(at) < 40);
    let top = doc.top_offset();
    r.check("E6 an offset two thirds into 1 MB lands at the top", top.abs_diff(at) < 40, format!("asked {at}, top {top}"));
    window.close();
}

/// A folder of test images, removed afterwards.
struct ImageFolder(std::path::PathBuf);

impl ImageFolder {
    fn new() -> ImageFolder {
        let p = std::env::temp_dir().join(format!("tvmv-check-images-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(p.join("img")).unwrap();
        ImageFolder(p)
    }
    fn png(&self, name: &str, w: i32, h: i32) {
        let pixbuf = gtk4::gdk_pixbuf::Pixbuf::new(gtk4::gdk_pixbuf::Colorspace::Rgb, true, 8, w, h).unwrap();
        pixbuf.fill(0xff0000ff);
        pixbuf.savev(self.0.join(name), "png", &[]).unwrap();
    }
    fn doc(&self) -> std::path::PathBuf {
        self.0.join("doc.md")
    }
}

impl Drop for ImageFolder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Dark pixels in `widget` as the window draws it now (a caret is dark).
fn rendered_ink(window: &gtk4::Window, widget: &gtk4::Widget) -> usize {
    // A fresh frame: the paintable shows the last one drawn.
    window.queue_draw();
    widget.queue_draw();
    settle();
    until(Duration::from_millis(300), || false);
    let paintable = gtk4::WidgetPaintable::new(Some(widget));
    let snapshot = gtk4::Snapshot::new();
    let (w, h) = (widget.width(), widget.height());
    paintable.snapshot(&snapshot, w as f64, h as f64);
    let (Some(node), Some(renderer)) = (snapshot.to_node(), window.renderer()) else { return usize::MAX };
    let texture = renderer.render_texture(&node, None);
    let mut data = vec![0u8; (texture.width() * texture.height() * 4) as usize];
    texture.download(&mut data, (texture.width() * 4) as usize);
    // Skip a 2-pixel frame: the cell's rules.
    let tw = texture.width() as usize;
    let th = texture.height() as usize;
    let mut dark = 0;
    for y in 2..th.saturating_sub(2) {
        for x in 2..tw.saturating_sub(2) {
            let p = &data[(y * tw + x) * 4..(y * tw + x) * 4 + 4];
            // BGRA premultiplied; dark and opaque.
            let lum = (p[0] as u32 + p[1] as u32 + p[2] as u32) / 3;
            if p[3] > 128 && lum < 120 {
                dark += 1;
            }
        }
    }
    dark
}

fn line_height(doc: &DocumentView, at: usize) -> i32 {
    let offset = doc.model.borrow().source.to_buffer(at);
    doc.view.line_yrange(&doc.buffer.iter_at_offset(offset)).1
}

fn open_with_images(folder: &ImageFolder, text: &str, editable: bool) -> (Rc<DocumentView>, gtk4::Window) {
    let doc = DocumentView::new(theme());
    doc.set_document_path(Some(folder.doc()));
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

fn settled(doc: &DocumentView, address: &str) -> Option<crate::native::document_view::ImageState> {
    use crate::native::document_view::ImageState;
    until(Duration::from_secs(5), || matches!(doc.image_state(address), Some(ImageState::Loaded | ImageState::Failed)));
    settle();
    doc.image_state(address)
}

fn image_checks(r: &mut Report) {
    use crate::native::document_view::ImageState;
    println!("\nF. images");
    let folder = ImageFolder::new();
    folder.png("img/chart.png", 200, 100);
    folder.png("wide.png", 4000, 400);
    let em = theme().em() as i32;

    let text = "Intro.\n\n![A chart](img/chart.png)\n\nAfter.\n";
    let (doc, window) = open_with_images(&folder, text, false);
    let at = text.find("![").unwrap();
    let state = settled(&doc, "img/chart.png");
    let height = line_height(&doc, at);
    r.check(
        "F1 a block image hides its source and its line takes the picture's height plus an em",
        state == Some(ImageState::Loaded)
            && doc.hidden_at(at)
            && doc.hidden_at(at + "![A chart](img/chart.png)".len() - 1)
            && (height - (100 + em)).abs() <= 4,
        format!("{state:?}, line {height}, want {}", 100 + em),
    );
    window.close();

    let (doc, window) = open_with_images(&folder, "![wide](wide.png)\n", false);
    settled(&doc, "wide.png");
    let column = doc.model.borrow().column_width;
    let height = line_height(&doc, 0);
    let want = (400.0 * column as f64 / 4000.0).round() as i32 + em;
    r.check("F2 a wide image scales down to the column", (height - want).abs() <= 4, format!("line {height}, want {want} (column {column})"));
    window.close();

    let (doc, window) = open_with_images(&folder, "![A chart](img/chart.png)\n", true);
    settled(&doc, "img/chart.png");
    doc.set_caret(4);
    doc.reveal(true);
    settle();
    let height = line_height(&doc, 0);
    r.check(
        "F3 revealing shows the source instead of the picture",
        !doc.hidden_at(0) && height < 100,
        format!("line {height}"),
    );
    // Mid-edit the line stops being an image; the source stays until the
    // caret leaves (reported on macOS: it flipped back and forth).
    let close = doc.text().find(')').unwrap();
    doc.set_caret(close + 1);
    doc.view.emit_by_name::<()>("backspace", &[]);
    settle();
    let mid = !doc.hidden_at(0);
    type_text(&doc, ")");
    settle();
    r.check(
        "F4 a revealed image stays revealed while its source is edited",
        mid && !doc.hidden_at(0) && doc.text() == "![A chart](img/chart.png)\n" && doc.is_revealing(),
        format!("{:?}, revealing {}", doc.text(), doc.is_revealing()),
    );
    window.close();

    let text = "![Missing chart](nope.png)\n\nText.\n";
    let (doc, window) = open_with_images(&folder, text, false);
    let state = settled(&doc, "nope.png");
    let height = line_height(&doc, 0);
    let body_line = line_height(&doc, text.find("Text").unwrap());
    r.check(
        "F5 a missing image keeps its source hidden on a normal line (the alt text is drawn)",
        state == Some(ImageState::Failed) && doc.hidden_at(0) && height == body_line,
        format!("{state:?}, line {height}, a text line {body_line}"),
    );
    window.close();

    let doc = DocumentView::new(theme());
    doc.max_image_pixels.set(10_000);
    doc.set_document_path(Some(folder.doc()));
    doc.load("![c](img/chart.png)\n".into());
    let state = settled(&doc, "img/chart.png");
    r.check("F6 an image over the pixel limit is not decoded", state == Some(ImageState::Failed), format!("{state:?}"));

    let (doc, window) = open_with_images(&folder, "Before.\n", true);
    let texture: gtk4::gdk::Texture = gtk4::gdk::MemoryTexture::new(
        40,
        20,
        gtk4::gdk::MemoryFormat::R8g8b8a8,
        &glib::Bytes::from_owned(vec![255u8; 40 * 20 * 4]),
        40 * 4,
    )
    .upcast();
    doc.set_caret(7);
    let pasted = doc.paste_image(&texture);
    let files: Vec<String> = std::fs::read_dir(folder.0.join("images"))
        .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    let name = files.first().cloned().unwrap_or_default();
    let state = settled(&doc, &format!("images/{name}"));
    r.check(
        "F7 pasting an image saves it beside the document and links it on its own paragraph",
        pasted
            && files.len() == 1
            && name.starts_with("doc-")
            && doc.text() == format!("Before.\n\n![](images/{name})\n")
            && state == Some(ImageState::Loaded),
        format!("{files:?} {:?} {state:?}", doc.text()),
    );
    doc.set_editable(false);
    r.check("F8 a read-only document never writes a pasted image", !doc.paste_image(&texture), "");
    window.close();
}

fn spelling_checks(r: &mut Report) {
    println!("\nG. spelling");
    let text = "A wrold here.\n\nSome `wrold` code, [a link](https://wrold.example/wrold) and <https://wrold.example>.\n\n```\nwrold\n```\n";
    let (doc, window) = open(text, false);
    if let Some(checker) = doc.spelling().checker() {
        checker.set_language("en_US");
    }
    doc.spelling().invalidate_all();
    let misspelled = |doc: &DocumentView, at: usize| {
        let Some(tag) = doc.spelling().tag() else { return false };
        let offset = doc.model.borrow().source.to_buffer(at);
        doc.buffer.iter_at_offset(offset).has_tag(&tag)
    };
    let first = text.find("wrold").unwrap();
    let marked = until(Duration::from_secs(3), || misspelled(&doc, first + 1));
    settle();
    let exempt: Vec<usize> = text.match_indices("wrold").skip(1).map(|(i, _)| i).collect();
    let flagged: Vec<usize> = exempt.iter().copied().filter(|&i| misspelled(&doc, i + 1)).collect();
    r.check("G1 a misspelling is marked, read-only too", marked, format!("language {:?}", doc.spelling().language()));
    r.check(
        "G2 code, code blocks and URLs are not spell-checked",
        marked && flagged.is_empty(),
        format!("flagged at {flagged:?} of {exempt:?}"),
    );
    // The menu's sections: spelling while editing, then Comment / Suggest Edit.
    let sections = |doc: &DocumentView| doc.view.extra_menu().map_or(0, |m| m.n_items());
    r.check("G3 corrections are offered only while editing", sections(&doc) == 1, format!("{} sections", sections(&doc)));
    doc.set_editable(true);
    let end = doc.text().find(" here").unwrap() + " here".len();
    doc.set_caret(end);
    type_text(&doc, " teh");
    type_text(&doc, " ");
    let at = end + 1;
    let typed = until(Duration::from_secs(3), || misspelled(&doc, at + 1));
    r.check(
        "G4 a word typed while editing is checked, and the menu offers corrections",
        typed && sections(&doc) == 2,
        format!("{:?}", &doc.text()[..at + 4]),
    );
    doc.set_spelling(false);
    settle();
    r.check(
        "G5 turning spelling off clears the marks and the corrections menu",
        !misspelled(&doc, first + 1) && !misspelled(&doc, at + 1) && sections(&doc) == 1,
        "",
    );
    window.close();

    // A table's anchor replaces the adapter; exemptions must survive that.
    let text = "A wrold here.\n\n| A | B |\n|---|---|\n| x | y |\n\nSome `wrold` code.\n";
    let (doc, window) = open(text, false);
    settle();
    if let Some(checker) = doc.spelling().checker() {
        checker.set_language("en_US");
    }
    doc.spelling().invalidate_all();
    let first = text.find("wrold").unwrap();
    let marked = until(Duration::from_secs(3), || misspelled(&doc, first + 1));
    settle();
    let code = text.rfind("wrold").unwrap();
    r.check(
        "G6 with a table in the document, prose is checked and code is not",
        doc.table_grids().len() == 1 && marked && !misspelled(&doc, code + 1),
        format!("marked {marked}, code flagged {}", misspelled(&doc, code + 1)),
    );
    window.close();
}

fn table_checks(r: &mut Report) {
    use crate::native::document_view::CellKey;
    use crate::table_source::Command;
    println!("\nH. tables");
    let text = "Intro.\n\n| Name | Score |\n|:-----|------:|\n| Ada  | 10 |\n| Bob | 7 |\n\nAfter.\n";
    let (doc, window) = open(text, false);
    settle();
    let grids = doc.table_grids();
    let start = text.find("| Name").unwrap();
    r.check(
        "H1 a table shows as a grid over its hidden source",
        grids.len() == 1
            && grids[0].cell_texts() == [["Name", "Score"], ["Ada", "10"], ["Bob", "7"]]
            && doc.hidden_at(start)
            && doc.hidden_at(text.find("| Bob").unwrap()),
        format!("{} grids, {:?}", grids.len(), grids.first().map(|g| g.cell_texts())),
    );
    let grid = Rc::clone(&grids[0]);
    // The grid sits between the lines around it, and within the column.
    let line_bottom = |at: usize| {
        let offset = doc.model.borrow().source.to_buffer(at);
        let (y, h) = doc.view.line_yrange(&doc.buffer.iter_at_offset(offset));
        y + h
    };
    let line_top = |at: usize| doc.line_top(at);
    let (gw, gh) = (grid.widget.width(), grid.widget.height());
    let gy = grid.widget.compute_bounds(&doc.view).map_or(-1.0, |b| b.y()) as i32;
    let gy = doc.view.window_to_buffer_coords(gtk4::TextWindowType::Widget, 0, gy).1;
    let (above, below) = (line_bottom(text.find("Intro").unwrap()), line_top(text.find("After").unwrap()));
    let column = doc.model.borrow().column_width;
    r.check(
        "H2 the grid sits between the lines around it, within the column",
        gh > 60 && gy >= above && gy + gh <= below && gw <= column,
        format!("grid {gw}x{gh} at {gy}, line above ends {above}, line below starts {below}, column {column}"),
    );
    // The caret passes the table as one block.
    let anchor = doc.model.borrow().source.to_buffer(start) - 1;
    doc.buffer.place_cursor(&doc.buffer.iter_at_offset(anchor));
    let forward_to = doc.selection().start;
    let after = text.find("\nAfter").unwrap();
    doc.set_caret(after);
    doc.buffer.place_cursor(&doc.buffer.iter_at_offset(anchor + 1));
    let back_to = doc.selection().start;
    r.check(
        "H2b the caret never rests beside a grid: it passes the table",
        forward_to == text.find("\n\nAfter").unwrap() + 1 && back_to == start - 1,
        format!("forward to {forward_to}, back to {back_to}"),
    );
    let x = grid.widget.compute_bounds(&doc.view).map_or(-1.0, |b| b.x());
    r.check(
        "H3 the grid lines up with the text",
        (x - doc.view.left_margin() as f32).abs() <= 1.0,
        format!("grid at {x}, text at {}", doc.view.left_margin()),
    );
    // Clicks and keys over a cell are the cell's, not the document's.
    let centre = grid.cell(1, 0).and_then(|c| c.view.compute_bounds(&doc.view)).map(|b| (b.x() + b.width() / 2.0, b.y() + b.height() / 2.0));
    let over_cell = centre.is_some_and(|(x, y)| doc.over_child(x as f64, y as f64));
    let over_text = doc.over_child(10.0, 10.0);
    r.check("H3b a point over a cell is the cell's, one over the text is not", over_cell && !over_text, format!("{centre:?}"));
    {
        // With comments in the document too: their column once covered the
        // text, cells included, and took their clicks.
        let text = "A {==comment==}[^rv-aaaa] here.\n\n| A | B |\n|---|---|\n| one | two |\n\nAfter.\n\n[^rv-aaaa]: @x 2026-10-13: Hm.\n";
        let (doc, window) = open(text, false);
        settle();
        until(Duration::from_millis(300), || false);
        settle();
        let cell = doc.table_grids().first().and_then(|g| g.cell(1, 0));
        let picked = cell.as_ref().and_then(|c| {
            let b = c.view.compute_bounds(&doc.view)?;
            let mut w = doc.view.pick((b.x() + b.width() / 2.0) as f64, (b.y() + b.height() / 2.0) as f64, gtk4::PickFlags::DEFAULT);
            while let Some(x) = w {
                if x == *c.view.upcast_ref::<gtk4::Widget>() {
                    return Some(true);
                }
                w = x.parent();
            }
            Some(false)
        });
        r.check("H3c with comments beside the text, a click over a cell reaches the cell", picked == Some(true), format!("{picked:?}"));
        window.close();
    }
    let cell = grid.cell(1, 0).unwrap();
    r.check("H4 cells are read-only until editing is on", !cell.is_editable(), "");
    doc.set_editable(true);
    let cell = grid.cell(1, 0).unwrap();
    cell.set_caret(3);
    type_text(&cell, "m");
    settle();
    let typed = doc.text().contains("| Adam  |") && grid.cell_texts()[1][0] == "Adam";
    grid.press(1, 0, CellKey::Undo);
    settle();
    r.check(
        "H5 typing in a cell edits the source, and undoes in one step",
        cell.is_editable() && typed && doc.text() == text && grid.cell_texts()[1][0] == "Ada",
        format!("typed {typed}, after undo {:?}", doc.text()),
    );
    let cell = grid.cell(2, 1).unwrap();
    cell.set_caret(1);
    type_text(&cell, "|");
    settle();
    r.check("H6 a typed pipe is escaped in the source", doc.text().contains("| 7\\| |"), format!("{:?}", doc.text()));
    grid.press(2, 1, CellKey::Undo);
    settle();
    let before = doc.text();
    grid.cell(1, 0).unwrap().view.grab_focus();
    grid.press(1, 0, CellKey::Next);
    let a = grid.focused();
    grid.press(1, 1, CellKey::Next);
    let b = grid.focused();
    grid.press(2, 0, CellKey::Previous);
    let c = grid.focused();
    grid.press(1, 1, CellKey::Down);
    let d = grid.focused();
    r.check(
        "H7 Tab, Shift+Tab and Return move between cells, and never edit",
        a == Some((1, 1)) && b == Some((2, 0)) && c == Some((1, 1)) && d == Some((2, 1)) && doc.text() == before,
        format!("{a:?} {b:?} {c:?} {d:?}"),
    );
    // The table's buttons show while a cell has focus, in edit mode.
    grid.cell(1, 0).unwrap().view.grab_focus();
    settle();
    until(Duration::from_millis(400), || grid.tools_shown());
    r.check("H7b the table's buttons show while one of its cells has focus", grid.tools_shown(), "");
    // Only the focused cell shows a caret, also after moving around and in
    // cells a command just made: count dark pixels (a caret) in an empty
    // cell that does not have focus.
    grid.perform(Command::InsertRowBelow, 1, 0);
    settle();
    let grid = Rc::clone(&doc.table_grids()[0]);
    grid.press(1, 0, CellKey::Down);
    settle();
    grid.press(2, 0, CellKey::Next);
    settle();
    grid.press(2, 1, CellKey::Previous);
    settle();
    grid.press(2, 0, CellKey::Down);
    settle();
    let ink = |cell: &DocumentView| rendered_ink(&window, cell.view.upcast_ref());
    let (empty_a, empty_b) = (grid.cell(2, 1).map(|c| ink(&c)), grid.cell(2, 0).map(|c| ink(&c)));
    r.check(
        "H7d unfocused cells show no caret, after moving through them",
        grid.focused() == Some((3, 0)) && empty_a == Some(0) && empty_b == Some(0),
        format!("focused {:?}, dark pixels in the empty cells {empty_a:?} {empty_b:?}", grid.focused()),
    );
    doc.undo();
    settle();
    let grid = Rc::clone(&doc.table_grids()[0]);
    grid.cell(1, 0).unwrap().view.grab_focus();
    settle();
    // A shortcut runs its command; the menu shows the shortcuts.
    grid.press(1, 0, CellKey::Command(Command::InsertColumnRight));
    settle();
    let widened = doc.table_grids()[0].cell_texts().iter().all(|r| r.len() == 3);
    doc.undo();
    settle();
    let grid = Rc::clone(&doc.table_grids()[0]);
    let menu_accels = grid.cell(1, 0).and_then(|c| c.view.extra_menu()).is_some_and(|menu| {
        // The cell's menu: spelling, then the table commands' two sections.
        let mut accels = 0;
        for i in 0..menu.n_items() {
            if let Some(section) = menu.item_link(i, "section") {
                for j in 0..section.n_items() {
                    if let Some(inner) = section.item_link(j, "section") {
                        for k in 0..inner.n_items() {
                            if inner.item_attribute_value(k, "accel", None).is_some() {
                                accels += 1;
                            }
                        }
                    }
                    if section.item_attribute_value(j, "accel", None).is_some() {
                        accels += 1;
                    }
                }
            }
        }
        accels >= Command::ALL.len()
    });
    r.check(
        "H7c a table shortcut runs its command, and the menu shows the shortcuts",
        widened && menu_accels,
        format!("widened {widened}, menu shortcuts {menu_accels}"),
    );
    grid.perform(Command::InsertRowBelow, 1, 0);
    settle();
    let grid = Rc::clone(&doc.table_grids()[0]);
    r.check(
        "H8 adding a row rewrites the table",
        doc.text().contains("| Ada  |    10 |\n|      |       |\n| Bob  |     7 |") && grid.cell_texts().len() == 4,
        format!("{:?}", doc.text()),
    );
    doc.undo();
    settle();
    let grid = Rc::clone(&doc.table_grids()[0]);
    grid.press(1, 0, CellKey::Reveal);
    settle();
    r.check(
        "H9 revealing from a cell shows the raw source",
        !doc.hidden_at(start) && doc.table_grids().is_empty() && doc.view.has_focus(),
        format!("{} grids", doc.table_grids().len()),
    );
    // Deleting across the table with spelling on (libspelling once aborted).
    doc.reveal(false);
    settle();
    let len = doc.text().len();
    doc.select(0..len);
    doc.buffer.begin_user_action();
    doc.buffer.delete_selection(true, true);
    doc.buffer.end_user_action();
    settle();
    doc.undo();
    settle();
    doc.load(text.to_string());
    settle();
    r.check("H10 deleting across a table, undoing it and reloading keep working", doc.text() == text && doc.table_grids().len() == 1, "");
    window.close();

    let text = "Text `outside`.\n\n| A |\n|---|\n| `inside` |\n\nAfter.\n";
    let (doc, window) = open(text, false);
    settle();
    let pills = |doc: &DocumentView| {
        let model = doc.model.borrow();
        model
            .prepared
            .layout
            .styles
            .iter()
            .filter(|s| s.style == crate::layout::Style::Code && !super::view::in_hidden_table(&model, &s.range))
            .count()
    };
    let hidden = pills(&doc);
    doc.reveal_table(text.find("| A").unwrap());
    settle();
    r.check("H11 a hidden table's source draws no code pills", hidden == 1 && pills(&doc) == 2, format!("{hidden}, revealed {}", pills(&doc)));
    window.close();

    // Hit-testing every point (as the pointer and clicks do) aborted GTK
    // below the text of any line with hidden text: an image line, a table's
    // anchor line, a document's last line (styler::NO_ROOM_BELOW).
    let folder = ImageFolder::new();
    folder.png("pic.png", 300, 120);
    let text = "## Tables\n\n| Feature  | Reading | Editing |\n|:---------|:-------:|--------:|\n| Outline  | yes     | yes     |\n\nClick a cell while editing and type; Tab moves to the next one.\n\n![pic](pic.png)\n\n> A quote after the picture.\n\n![pic](pic.png)\n\n```\ncode after it\n```\n\n> ```\n> code in a quote\n> ```\n\nThe last line has **bold** and no newline";
    let (doc, window) = open_with_images(&folder, text, false);
    settled(&doc, "pic.png");
    if let Some(adj) = doc.view.vadjustment() {
        let mut top = 0.0;
        loop {
            adj.set_value(top);
            settle();
            let (w, h) = (doc.view.width(), doc.view.height());
            for y in (0..h).step_by(3) {
                for x in (0..w).step_by(9) {
                    let (bx, by) = doc.view.window_to_buffer_coords(gtk4::TextWindowType::Widget, x, y);
                    // Below the end the view keeps the pointer from GTK.
                    if !doc.below_risky_end(by) {
                        let _ = doc.view.iter_at_location(bx, by);
                    }
                }
            }
            if top >= adj.upper() - adj.page_size() {
                break;
            }
            top = (top + adj.page_size() / 2.0).min(adj.upper() - adj.page_size());
        }
    }
    r.check("H12 the pointer can go anywhere, around pictures, tables and the last line", doc.table_grids().len() == 1, "");
    window.close();
}

fn review_checks(r: &mut Report) {
    use crate::native::review_cards::Action;
    println!("\nI. review");
    const DAY: &str = "2026-10-14";
    let doc_text = "Intro paragraph.\n\nThe {==cache==}[^rv-a1b2] is {~~cold~>warm~~}[^rv-c3d4] today.\n\nAnother line with a point.[^rv-e5f6]\n\n[^rv-a1b2]: @ulf 2026-10-14: Why?\n    @claude 2026-10-14: Because.\n[^rv-c3d4]: @claude 2026-10-14 suggestion: Warmer.\n[^rv-e5f6]: @ulf 2026-10-14: Source?\n";
    let (doc, window) = open(doc_text, false);
    window.set_default_size(1200, 700);
    settle();
    until(Duration::from_millis(500), || false);
    settle();
    let column = doc.review_cards().expect("a comment column");
    let cards = column.cards.borrow().clone();
    let ids: Vec<String> = cards.iter().map(|c| c.id()).collect();
    let bounds: Vec<(f32, f32, f32)> = cards
        .iter()
        .filter_map(|c| c.widget.compute_bounds(&doc.view).map(|b| (b.x(), b.y(), b.y() + b.height())))
        .collect();
    let text_end = (doc.view.left_margin() + doc.model.borrow().column_width) as f32;
    let beside = bounds.iter().all(|b| b.0 > text_end);
    let apart = bounds.windows(2).all(|w| w[0].2 <= w[1].1);
    let line = doc.view.buffer_to_window_coords(gtk4::TextWindowType::Widget, 0, doc.line_top(doc_text.find("cache").unwrap())).1 as f32;
    r.check(
        "I1 one card per thread, beside the text, in order, without overlapping, the first on its line",
        ids == ["rv-a1b2", "rv-c3d4", "rv-e5f6"] && beside && apart && bounds.first().is_some_and(|b| (b.1 - line).abs() <= 2.0),
        format!("{ids:?} {bounds:?} text ends {text_end}, line {line}"),
    );
    // The caret in an anchor focuses its card; only that one shows actions.
    doc.set_caret(doc_text.find("cold").unwrap() + 1);
    settle();
    let focused: Vec<bool> = column.cards.borrow().iter().map(|c| c.is_focused()).collect();
    r.check("I2 the caret in an anchor focuses its card", focused == [false, true, false], format!("{focused:?}"));
    // Typing elsewhere keeps the cards, and a half-written reply.
    let first = Rc::clone(&column.cards.borrow()[0]);
    if let Some(reply) = &first.reply {
        reply.set_text("half a reply");
    }
    doc.set_editable(true);
    doc.set_caret(doc_text.find("Intro").unwrap() + 5);
    type_text(&doc, "x");
    settle();
    let kept = Rc::ptr_eq(&first, &column.cards.borrow()[0]) && first.reply.as_ref().is_some_and(|e| e.text() == "half a reply");
    r.check("I3 typing keeps the cards and a half-written reply", kept, "");
    doc.undo();
    settle();
    // Accept from the suggestion's card button.
    let suggestion = column.cards.borrow().iter().find(|c| c.id() == "rv-c3d4").cloned();
    if let Some(button) = suggestion.and_then(|c| c.button("Accept")) {
        button.emit_clicked();
    }
    settle();
    r.check(
        "I4 a card's Accept settles its suggestion",
        doc.text().contains("is warm today.") && !doc.text().contains("rv-c3d4"),
        format!("{:?}", doc.text()),
    );
    // Reply from the comment's card.
    let comment = column.cards.borrow().iter().find(|c| c.id() == "rv-e5f6").cloned();
    if let Some(entry) = comment.as_ref().and_then(|c| c.reply.clone()) {
        entry.set_text("Here.");
        entry.emit_activate();
    }
    settle();
    let author = crate::review_ops::current_author(None);
    r.check(
        "I5 a card's reply appends to its thread",
        doc.text().contains(&format!("[^rv-e5f6]: @ulf 2026-10-14: Source?\n    @{author} ")),
        format!("{:?}", doc.text()),
    );
    // Next and previous thread move the caret, wrapping round.
    doc.set_caret(0);
    doc.move_to_thread(true);
    let a = doc.selection().start;
    doc.move_to_thread(true);
    let b = doc.selection().start;
    doc.move_to_thread(false);
    let c = doc.selection().start;
    r.check(
        "I6 next and previous thread move the caret",
        a == doc.text().find("cache").unwrap() && b > a && c == a,
        format!("{a} {b} {c}"),
    );
    window.close();

    // Cards scroll with the text.
    let long = format!("{}{doc_text}", "Filler paragraph.\n\n".repeat(30));
    let (doc, window) = open(&long, false);
    settle();
    until(Duration::from_millis(300), || false);
    let card = doc.review_cards().and_then(|c| c.cards.borrow().first().cloned());
    let y = |doc: &DocumentView| card.as_ref().and_then(|c| c.widget.compute_bounds(&doc.view)).map_or(0.0, |b| b.y());
    let before = y(&doc);
    if let Some(adj) = doc.view.vadjustment() {
        adj.set_value(120.0);
    }
    settle();
    let after = y(&doc);
    let scrolled = doc.view.vadjustment().map_or(0.0, |a| a.value()) as f32;
    r.check(
        "I1b the cards scroll with the text",
        scrolled > 0.0 && (before - after - scrolled).abs() <= 1.0,
        format!("card at {before}, then {after}, scrolled {scrolled}"),
    );
    window.close();

    let text = "The cache is stale.\n";
    let (doc, window) = open(text, false);
    let cache = text.find("cache").unwrap();
    doc.select(cache..cache + 5);
    let id = doc.add_comment("Why?", "ulf", DAY);
    settle();
    let added = doc.text();
    doc.undo();
    settle();
    r.check(
        "I7 commenting on the selection is one undoable edit, while reading",
        id.is_some() && added.starts_with("The {==cache==}[^rv-") && doc.text() == text,
        format!("{added:?}"),
    );
    let two = "One.\n\nTwo.\n";
    doc.load(two.into());
    settle();
    doc.select(0..two.len());
    r.check(
        "I8 a comment needs a selection within one block",
        doc.add_comment("x", "ulf", DAY).is_none() && doc.text() == two,
        format!("{:?}", doc.text()),
    );
    doc.load(text.into());
    settle();
    doc.select(cache..cache + 5);
    let sid = doc.add_suggestion("index", "Clearer.", "ulf", DAY);
    r.check(
        "I9 suggesting replaces the selection",
        sid.is_some() && doc.text().starts_with("The {~~cache~>index~~}[^rv-"),
        format!("{:?}", doc.text()),
    );
    // The composer: a comment on the selection.
    doc.load(text.into());
    settle();
    doc.select(cache..cache + 5);
    doc.open_composer(false);
    settle();
    let column = doc.review_cards().expect("a column");
    let composer = column.composer.borrow().clone();
    let opened = composer.is_some() && doc.model.borrow().review_reserve > 0;
    if let Some(c) = &composer {
        c.body.set_text("Why?");
        c.body.emit_activate();
    }
    settle();
    r.check(
        "I10 the composer adds a comment on the selection, and closes",
        opened && column.composer.borrow().is_none() && doc.text().starts_with("The {==cache==}[^rv-") && doc.text().contains(": Why?"),
        format!("{:?}", doc.text()),
    );
    // Resolving the last thread takes the column away.
    let id = doc.text().split("[^").nth(1).and_then(|s| s.split(']').next()).unwrap_or("").to_string();
    doc.card_action(&id, Action::Resolve);
    settle();
    let shown = |doc: &DocumentView| {
        let mut n = 0;
        let mut c = doc.view.first_child();
        while let Some(w) = c {
            let mut stack = vec![w.clone()];
            while let Some(x) = stack.pop() {
                if x.has_css_class("tvmv-card") && x.is_visible() && x.parent().is_some_and(|p| p.is_visible()) {
                    n += 1;
                }
                let mut k = x.first_child();
                while let Some(ch) = k {
                    k = ch.next_sibling();
                    stack.push(ch);
                }
            }
            c = w.next_sibling();
        }
        n
    };
    r.check("I13 a resolved card leaves the screen", shown(&doc) == 0, format!("{} cards shown", shown(&doc)));
    r.check(
        "I11 the column goes when the last comment does",
        doc.text() == text && doc.model.borrow().review_reserve == 0,
        format!("{:?}, reserve {}", doc.text(), doc.model.borrow().review_reserve),
    );
    // A composer whose text changed under it says so.
    doc.select(cache..cache + 5);
    doc.open_composer(false);
    settle();
    doc.set_editable(true);
    doc.set_caret(0);
    type_text(&doc, "x");
    settle();
    let composer = column.composer.borrow().clone();
    if let Some(c) = &composer {
        c.body.set_text("Late");
        c.body.emit_activate();
    }
    settle();
    let refused = composer.is_some_and(|c| c.message.is_visible()) && !doc.text().contains("rv-");
    r.check("I12 a composer refuses text that changed under it", refused, format!("{:?}", doc.text()));
    window.close();
}

/// Keys and clicks inside the view: the document's view holds other views
/// (table cells), and whatever sees an event first in the capture phase on
/// the outer one sees the inner ones' events too. GTK 4 can't synthesize
/// input, so these check the arrangement that keeps events where they belong.
fn input_checks(r: &mut Report) {
    use crate::native::document_view::{CellKey, TVMV_KEYS};
    println!("\nK. input inside the view");
    let text = "A {==comment==}[^rv-aaaa] here.\n\n| A | B |\n|---|---|\n| one | two |\n\nAfter.\n\n[^rv-aaaa]: @x 2026-10-13: Hm.\n";
    let (doc, window) = open(text, true);
    settle();
    until(Duration::from_millis(300), || false);
    settle();
    let grid = doc.table_grids()[0].clone();
    let mut views: Vec<gtk4::Widget> = vec![doc.view.clone().upcast()];
    for r in 0..2 {
        for c in 0..2 {
            if let Some(cell) = grid.cell(r, c) {
                views.push(cell.view.clone().upcast());
            }
        }
    }
    let stray: Vec<String> = views
        .iter()
        .flat_map(|v| v.observe_controllers().iter::<glib::Object>().flatten().collect::<Vec<_>>())
        .filter_map(|c| c.downcast::<gtk4::EventControllerKey>().ok())
        .filter(|k| k.propagation_phase() == gtk4::PropagationPhase::Capture && k.name().as_deref() != Some(TVMV_KEYS))
        .map(|k| format!("{:?}", k.name()))
        .collect();
    r.check(
        "K1 no key handler but ours sees keys in the capture phase (it would get a cell's keys first)",
        stray.is_empty() && views.len() == 5,
        format!("{} views, stray {stray:?}", views.len()),
    );
    // The document's own handler leaves a focused cell's keys alone.
    let cell = grid.cell(1, 0).unwrap();
    cell.view.grab_focus();
    settle();
    let ours = doc
        .view
        .observe_controllers()
        .iter::<glib::Object>()
        .flatten()
        .filter_map(|c| c.downcast::<gtk4::EventControllerKey>().ok())
        .find(|k| k.name().as_deref() == Some(TVMV_KEYS));
    let before = doc.text();
    let stopped = ours.map(|k| {
        k.emit_by_name::<bool>("key-pressed", &[&glib::translate::IntoGlib::into_glib(gtk4::gdk::Key::Return), &0u32, &gtk4::gdk::ModifierType::empty()])
    });
    r.check(
        "K2 with a cell focused, the document's key handler lets its keys through",
        stopped == Some(false) && doc.text() == before,
        format!("{stopped:?}"),
    );
    // A cell left behind keeps no selection (it would look like a second cursor).
    cell.select(0..cell.text().len());
    grid.press(1, 0, CellKey::Next);
    settle();
    r.check("K3 a cell left behind keeps no selection", !cell.buffer.has_selection(), "");
    window.close();
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
    doc.set_document_path(input.canonicalize().ok());
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
    // Pictures load and grids build after styling; let them land.
    let wait = std::env::var("TVMV_SHOT_WAIT").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
    until(Duration::from_millis(wait), || false);
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
    save_png(window.upcast_ref(), output)
}

/// Render `window` as it is now to a PNG.
pub fn save_png(window: &gtk4::Window, output: &str) -> glib::ExitCode {
    let paintable = gtk4::WidgetPaintable::new(Some(window));
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

/// Hover every point of the view after review edits (diagnostic:
/// `TVMV_TRACE_HOVER=FILE tvmv --self-check`).
fn trace_hover(path: &str) {
    let text = std::fs::read_to_string(path).unwrap();
    let (w, h) = std::env::var("TVMV_WINDOW_SIZE")
        .ok()
        .and_then(|s| {
            let (w, h) = s.split_once('x')?;
            Some((w.parse().ok()?, h.parse().ok()?))
        })
        .unwrap_or((1300, 950));
    let doc = DocumentView::new(theme());
    doc.set_document_path(std::path::Path::new(path).canonicalize().ok());
    doc.load(text.clone());
    let window = gtk4::Window::new();
    window.set_default_size(w, h);
    let scroller = gtk4::ScrolledWindow::new();
    scroller.set_hscrollbar_policy(gtk4::PolicyType::Never);
    scroller.set_child(Some(&doc.view));
    window.set_child(Some(&scroller));
    window.present();
    settle();
    until(Duration::from_millis(800), || false);
    let sweep = |label: &str| {
        settle();
        eprintln!("sweep after {label}");
        let Some(adj) = doc.view.vadjustment() else { return };
        let mut top = 0.0;
        loop {
            adj.set_value(top);
            settle();
            sweep_screen(&doc);
            if top >= adj.upper() - adj.page_size() {
                break;
            }
            top = (top + adj.page_size() / 2.0).min(adj.upper() - adj.page_size());
        }
        adj.set_value(0.0);
        settle();
    };
    fn sweep_screen(doc: &DocumentView) {
        let (w, h) = (doc.view.width(), doc.view.height());
        for y in (0..h).step_by(3) {
            for x in (0..w).step_by(7) {
                let (bx, by) = doc.view.window_to_buffer_coords(gtk4::TextWindowType::Widget, x, y);
                if std::env::var_os("TVMV_TRACE_HOVER_POINTS").is_some() {
                    let (line, _) = doc.view.line_at_y(by);
                    let mut end = line;
                    end.forward_to_line_end();
                    eprintln!("at {bx},{by}: line {} {:?}", line.line(), doc.buffer.text(&line, &end, true));
                }
                let _ = doc.view.iter_at_location(bx, by);
            }
        }
    }
    sweep("load");
    let Some(at) = text.find("cache") else {
        eprintln!("no crash");
        return;
    };
    doc.select(at..at + 5);
    doc.set_caret(text.find("lazily").or(text.find("cold")).unwrap() + 1);
    sweep("focus a card");
    doc.card_action("rv-p2x7", crate::native::review_cards::Action::Accept);
    sweep("accept");
    doc.undo();
    sweep("undo");
    let t = doc.text();
    let w = t.find("Select some").unwrap();
    doc.select(w..w + 6);
    doc.add_comment("Hi", "ulf", "2026-10-21");
    sweep("comment");
    doc.set_editable(true);
    doc.set_caret(t.find("Press").unwrap());
    type_text(&doc, "Now ");
    sweep("typing");
    doc.card_action("rv-k3f9", crate::native::review_cards::Action::Resolve);
    sweep("resolve");
    eprintln!("resolved: {}", !doc.text().contains("rv-k3f9"));
    eprintln!("no crash");
    window.close();
}

/// What a click over a table cell lands on (diagnostic:
/// `TVMV_TRACE_PICK=1 tvmv --self-check`).
fn trace_pick() {
    let text = "A {==comment==}[^rv-aaaa] here.\n\n| A | B |\n|---|---|\n| one | two |\n\nAfter.\n\n[^rv-aaaa]: @x 2026-10-13: Hm.\n";
    let (doc, window) = open(text, true);
    settle();
    until(Duration::from_millis(500), || false);
    settle();
    let grid = doc.table_grids()[0].clone();
    let cell = grid.cell(1, 0).unwrap();
    let b = cell.view.compute_bounds(&doc.view).unwrap();
    let (x, y) = (b.x() + b.width() / 2.0, b.y() + b.height() / 2.0);
    let mut w = doc.view.pick(x as f64, y as f64, gtk4::PickFlags::DEFAULT);
    while let Some(widget) = w {
        eprintln!("picked: {} {:?}", widget.type_().name(), widget.css_classes());
        if widget == *doc.view.upcast_ref::<gtk4::Widget>() {
            break;
        }
        w = widget.parent();
    }
    if let Ok(out) = std::env::var("TVMV_TRACE_PICK_SHOT") {
        doc.set_editable(true);
        grid.cell(1, 1).unwrap().view.grab_focus();
        settle();
        grid.press(1, 1, crate::native::document_view::CellKey::Previous);
        settle();
        until(Duration::from_millis(600), || false);
        settle();
        eprintln!("focused cell {:?}, main view focus {}, main cursor visible {}", grid.focused(), doc.view.has_focus(), doc.view.is_cursor_visible());
        for r in 0..2 {
            for c in 0..2 {
                if let Some(cell) = grid.cell(r, c) {
                    eprintln!("cell {r},{c}: focus {} cursor visible {}", cell.view.has_focus(), cell.view.is_cursor_visible());
                }
            }
        }
        save_png(window.upcast_ref(), &out);
    }
    eprintln!("cell editable {}, extra menu items {:?}", cell.is_editable(), cell.view.extra_menu().map(|m| m.n_items()));
    let popped = cell.view.activate_action("menu.popup", None);
    settle();
    let mut found = vec![];
    let mut stack = vec![cell.view.clone().upcast::<gtk4::Widget>()];
    while let Some(x) = stack.pop() {
        if x.type_().name().contains("Popover") {
            found.push(format!("{} visible {}", x.type_().name(), x.is_visible()));
        }
        let mut c = x.first_child();
        while let Some(ch) = c {
            c = ch.next_sibling();
            stack.push(ch);
        }
    }
    eprintln!("menu.popup: {popped:?}, popovers {found:?}");
    window.close();
}

pub fn run() -> glib::ExitCode {
    if std::env::var_os("TVMV_TRACE_PICK").is_some() {
        let _ = gtk4::init();
        trace_pick();
        return glib::ExitCode::SUCCESS;
    }
    if let Ok(path) = std::env::var("TVMV_TRACE_HOVER") {
        let _ = gtk4::init();
        trace_hover(&path);
        return glib::ExitCode::SUCCESS;
    }
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
    reader_checks(&mut r);
    image_checks(&mut r);
    spelling_checks(&mut r);
    table_checks(&mut r);
    review_checks(&mut r);
    input_checks(&mut r);
    for size in [64 * 1024, 1024 * 1024, 5 * 1024 * 1024] {
        perf_checks(&mut r, size);
    }
    println!("\nfailures: {}", r.failures);
    glib::ExitCode::from(r.failures.min(255) as u8)
}
