//! `TvmvView`: the GtkSourceView subclass that is the native reader/editor.
//! GtkSourceView is here for libspelling, which needs its buffer; its own
//! features (highlighting, bracket matching, indenting) are all off, and
//! TVMV's tags do the styling.
//!
//! It centres a column of the theme's measure, and draws what the styler
//! leaves room for, in the layer below the text: code-block backgrounds,
//! inline-code pills, quote rules, bullets, numbers, checkboxes and point
//! markers. Only items on screen are drawn: asking GTK where an offscreen
//! line is forces it to lay that line out.

use std::cell::RefCell;
use std::ops::Range;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, glib, graphene, gsk, pango};
use sourceview5::prelude::*;
use sourceview5::subclass::prelude::*;

use crate::layout::{ListItem, Style};
use crate::review_spans::SpanRole;

use super::document_view::{ImageState, Model};
use super::styler::quote_indent;
use super::theme::NativeTheme;

/// Font metrics by (family, size bits): ascent and descent in pixels.
type MetricsCache = Vec<((String, u64), (f64, f64))>;
type ColumnCallback = Box<dyn Fn(i32, i32)>;
type DrawnCallback = Box<dyn Fn(Range<usize>)>;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct TvmvView {
        pub model: RefCell<Option<Rc<RefCell<Model>>>>,
        pub metrics: RefCell<MetricsCache>,
        /// Told the column's x whenever it moves (indent tags follow it).
        pub on_column: RefCell<Option<ColumnCallback>>,
        /// Told the source range on screen after each frame is drawn.
        pub on_drawn: RefCell<Option<DrawnCallback>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for TvmvView {
        const NAME: &'static str = "TvmvNativeView";
        type Type = super::TvmvView;
        type ParentType = sourceview5::View;
    }

    impl ObjectImpl for TvmvView {}

    impl WidgetImpl for TvmvView {
        fn size_allocate(&self, width: i32, height: i32, baseline: i32) {
            self.obj().layout_column(width);
            self.parent_size_allocate(width, height, baseline);
        }
    }

    impl ViewImpl for TvmvView {}

    impl TextViewImpl for TvmvView {
        fn snapshot_layer(&self, layer: gtk4::TextViewLayer, snapshot: gtk4::Snapshot) {
            self.parent_snapshot_layer(layer, snapshot.clone());
            if layer != gtk4::TextViewLayer::BelowText {
                return;
            }
            let Some(model) = self.model.borrow().clone() else { return };
            let Ok(model) = model.try_borrow() else { return };
            self.obj().draw_below(&model, &snapshot);
        }
    }
}

glib::wrapper! {
    pub struct TvmvView(ObjectSubclass<imp::TvmvView>)
        @extends sourceview5::View, gtk4::TextView, gtk4::Widget,
        @implements gtk4::Accessible, gtk4::Buildable, gtk4::ConstraintTarget, gtk4::Scrollable;
}

impl Default for TvmvView {
    fn default() -> Self {
        Self::new()
    }
}

/// The items of `items` (in source order, each within a line) that start
/// in `visible`.
fn visible_slice<'a, T>(items: &'a [T], visible: &Range<usize>, start: impl Fn(&T) -> usize) -> &'a [T] {
    let from = items.partition_point(|i| start(i) < visible.start);
    let to = items.partition_point(|i| start(i) < visible.end);
    &items[from..to.max(from)]
}

/// Whether `range` is inside a table shown as a grid (its source hidden).
pub fn in_hidden_table(model: &Model, range: &Range<usize>) -> bool {
    let tables = &model.prepared.layout.tables;
    let i = tables.partition_point(|t| t.range.end < range.start);
    tables.get(i).is_some_and(|t| t.range.start <= range.start && range.end <= t.range.end && !model.is_revealed(&t.range))
}

fn rect(x: f64, y: f64, w: f64, h: f64) -> graphene::Rect {
    graphene::Rect::new(x as f32, y as f32, w as f32, h as f32)
}

fn rounded_fill(snapshot: &gtk4::Snapshot, r: &graphene::Rect, radius: f32, color: &gdk::RGBA) {
    let rounded = gsk::RoundedRect::from_rect(*r, radius);
    snapshot.push_rounded_clip(&rounded);
    snapshot.append_color(color, r);
    snapshot.pop();
}

impl TvmvView {
    pub fn new() -> Self {
        let view: TvmvView = glib::Object::new();
        view.set_highlight_current_line(false);
        view.set_show_line_numbers(false);
        view.set_auto_indent(false);
        view.set_indent_on_tab(false);
        view.set_smart_backspace(false);
        view.set_smart_home_end(sourceview5::SmartHomeEndType::Disabled);
        if let Ok(buffer) = view.buffer().downcast::<sourceview5::Buffer>() {
            buffer.set_highlight_syntax(false);
            buffer.set_highlight_matching_brackets(false);
            // No style scheme: it would set the text's colors over the theme's.
            buffer.set_style_scheme(None);
        }
        view.add_css_class("tvmv-native");
        view.set_wrap_mode(gtk4::WrapMode::WordChar);
        view.set_top_margin(36);
        view.set_bottom_margin(72);
        view
    }

    pub fn set_model(&self, model: Rc<RefCell<Model>>) {
        *self.imp().model.borrow_mut() = Some(model);
    }

    /// `f(range)`: the source range drawn on screen, after each frame.
    pub fn set_on_drawn(&self, f: impl Fn(Range<usize>) + 'static) {
        *self.imp().on_drawn.borrow_mut() = Some(Box::new(f));
    }

    /// `f(x, width)`: where the text column starts, and how wide it is.
    pub fn set_on_column(&self, f: impl Fn(i32, i32) + 'static) {
        *self.imp().on_column.borrow_mut() = Some(Box::new(f));
    }

    fn with_model<T>(&self, f: impl FnOnce(&Model) -> T) -> Option<T> {
        let model = self.imp().model.borrow().clone()?;
        let model = model.try_borrow().ok()?;
        Some(f(&model))
    }

    /// The width of `s` in the body font, in pixels.
    pub fn text_width(&self, s: &str) -> i32 {
        self.create_pango_layout(Some(s)).pixel_size().0
    }

    /// Centre a column of the theme's measure (or fill the width), with at
    /// least the theme's padding either side.
    pub fn layout_column(&self, width: i32) {
        let Some((measure, full, padding, reserve)) =
            self.with_model(|m| (m.theme.measure, m.theme.full_width, m.theme.padding, m.review_reserve))
        else {
            return;
        };
        // The comment column, when the document has one, takes its room on
        // the right; the text centres in what is left.
        let total = width;
        let width = (width - reserve).max(1);
        let zero = self.text_width("0") as f64;
        // A measured column keeps a readable minimum; a full-width one (a
        // table cell) is exactly what is left inside its padding.
        let available = (width as f64 - 2.0 * padding).max(if full { 1.0 } else { 200.0 });
        let column = if full { available } else { (measure * zero).min(available) };
        let x = padding.max((width as f64 - column) / 2.0).round() as i32;
        let right = (total - x - column.round() as i32).max(0);
        if self.left_margin() != x {
            self.set_left_margin(x);
        }
        if self.right_margin() != right {
            self.set_right_margin(right);
        }
        if let Some(f) = self.imp().on_column.borrow().as_ref() {
            f(x, column.round() as i32);
        }
    }

    /// Source range of the lines on screen. `line_at_y` always answers;
    /// `iter_at_location` does not past a line's end.
    fn visible_source(&self, model: &Model) -> Range<usize> {
        let visible = self.visible_rect();
        let (top, _) = self.line_at_y(visible.y());
        let (mut bottom, _) = self.line_at_y(visible.y() + visible.height());
        bottom.forward_line();
        model.source.to_source(top.offset())..model.source.to_source(bottom.offset())
    }

    /// Where the character at source offset `byte` is drawn, in buffer coordinates.
    fn char_rect(&self, model: &Model, byte: usize) -> gdk::Rectangle {
        self.location(&self.buffer().iter_at_offset(model.source.to_buffer(byte)))
    }

    /// Where `iter` is drawn: the caret's rectangle there. `iter_location`
    /// would be wrong after hidden text, which it measures as if it showed
    /// (GTK 4.14); the cursor geometry skips it, as the rendering does.
    pub fn location(&self, iter: &gtk4::TextIter) -> gdk::Rectangle {
        self.cursor_locations(Some(iter)).0
    }

    /// Ascent and descent of `family` at `size` pixels.
    fn metrics(&self, family: &str, size: f64) -> (f64, f64) {
        let key = (family.to_string(), size.to_bits());
        if let Some((_, m)) = self.imp().metrics.borrow().iter().find(|(k, _)| *k == key) {
            return *m;
        }
        let mut font = pango::FontDescription::new();
        font.set_family(family);
        font.set_absolute_size(size * pango::SCALE as f64);
        let metrics = self.pango_context().metrics(Some(&font), None);
        let m = (metrics.ascent() as f64 / pango::SCALE as f64, metrics.descent() as f64 / pango::SCALE as f64);
        self.imp().metrics.borrow_mut().push((key, m));
        m
    }

    /// The baseline of a character drawn in `rect` at the body size: line
    /// height spreads its leading evenly above and below the glyphs.
    fn baseline(&self, theme: &NativeTheme, rect: &gdk::Rectangle) -> f64 {
        let (ascent, descent) = self.metrics(&theme.body_family, theme.em());
        rect.y() as f64 + (rect.height() as f64 - ascent - descent) / 2.0 + ascent
    }

    /// A list item's first visible character: where its bullet is anchored.
    fn item_anchor(&self, model: &Model, item: &ListItem) -> gdk::Rectangle {
        self.char_rect(model, item.marker.end.min(model.source.text().len()))
    }

    /// The clickable checkbox of a task item, in buffer coordinates.
    pub fn task_box(&self, model: &Model, item: &ListItem) -> Option<graphene::Rect> {
        item.task?;
        let em = model.theme.em();
        let anchor = self.item_anchor(model, item);
        let baseline = self.baseline(&model.theme, &anchor);
        let side = em * 0.8;
        Some(rect(anchor.x() as f64 - side - em * 0.45, baseline - side * 0.95, side, side))
    }

    /// The task item whose checkbox is at buffer point (`x`, `y`), if any.
    pub fn task_at(&self, model: &Model, x: f64, y: f64) -> Option<usize> {
        let visible = self.visible_source(model);
        let layout = &model.prepared.layout;
        let first = layout.list_items.partition_point(|i| i.marker.start < visible.start);
        let items = visible_slice(&layout.list_items, &visible, |i| i.marker.start);
        items.iter().enumerate().find_map(|(k, item)| {
            let i = first + k;
            if model.is_revealed(&item.marker) {
                return None;
            }
            let b = self.task_box(model, item)?;
            let slack = 4.0;
            let hit = x >= b.x() as f64 - slack
                && x <= (b.x() + b.width()) as f64 + slack
                && y >= b.y() as f64 - slack
                && y <= (b.y() + b.height()) as f64 + slack;
            hit.then_some(i)
        })
    }

    fn draw_below(&self, model: &Model, snapshot: &gtk4::Snapshot) {
        let theme = &model.theme;
        let layout = &model.prepared.layout;
        let text = model.source.text();
        if layout.length != text.len() && !model.partial {
            // A parse is on its way: offsets would be off.
            return;
        }
        let visible = self.visible_source(model);
        if let Some(f) = self.imp().on_drawn.borrow().as_ref() {
            f(visible.clone());
        }
        let meets = |r: &Range<usize>| r.start < visible.end && r.end > visible.start;
        let em = theme.em();
        let column_x = self.left_margin() as f64;
        let column_w = (self.width() - self.left_margin() - self.right_margin()) as f64;

        // Block images, in the room their line reserves; a failed one shows
        // its alt text instead.
        let half = (em / 2.0).round();
        let scale = self.scale_factor() as f64;
        let on_pixels = |v: f64| (v * scale).round() / scale;
        for image in visible_slice(&layout.block_images, &visible, |i| i.range.start) {
            if model.is_revealed(&image.range) || image.range.end > text.len() {
                continue;
            }
            let state = model.images.get(&image.url);
            let at = self.buffer().iter_at_offset(model.source.to_buffer(image.range.start));
            if let (Some((w, h)), Some(texture)) = (model.image_size(image), state.and_then(|s| s.texture.as_ref())) {
                let (y, _) = self.line_yrange(&at);
                // On whole device pixels: the lines above can leave the line
                // at a fractional position, smearing every edge.
                let r = rect(on_pixels(column_x), on_pixels(y as f64 + half), w as f64, h as f64);
                snapshot.append_texture(texture, &r);
            } else if state.is_some_and(|s| s.state == ImageState::Failed) {
                let label = if image.alt.is_empty() { &image.url } else { &image.alt };
                let pango = self.create_pango_layout(Some(&format!("▨ {label}")));
                let mut font = pango::FontDescription::new();
                // The same fallback as the body text's CSS.
                font.set_family(&format!("{}, serif", theme.body_family));
                font.set_absolute_size(em * pango::SCALE as f64);
                font.set_style(pango::Style::Italic);
                pango.set_font_description(Some(&font));
                let line = self.location(&at);
                let (_, logical) = pango.pixel_extents();
                snapshot.save();
                snapshot.translate(&graphene::Point::new(
                    column_x as f32,
                    (line.y() as f64 + (line.height() - logical.height()) as f64 / 2.0) as f32,
                ));
                snapshot.append_layout(&pango, &theme.muted);
                snapshot.restore();
            }
        }

        // Code blocks: a rounded paper-deep panel behind the body lines.
        let first_block = layout.code_blocks.partition_point(|b| b.range.end <= visible.start);
        let blocks = layout.code_blocks[first_block..].iter().take_while(|b| b.range.start < visible.end);
        for block in blocks.filter(|b| !b.body.is_empty() && meets(&b.range)) {
            let top = self.char_rect(model, block.body.start);
            let last = text[..block.body.end].char_indices().next_back().map_or(block.body.start, |(i, _)| i);
            let bottom = self.char_rect(model, last.max(block.body.start));
            let y0 = top.y() as f64 - 8.0;
            let y1 = (bottom.y() + bottom.height()) as f64 + 8.0;
            rounded_fill(snapshot, &rect(column_x - 12.0, y0, column_w + 24.0, y1 - y0), 6.0, &theme.paper_deep);
        }

        // Inline code: a pill hugging the code font around its baseline, per line.
        let (mono_ascent, mono_descent) = self.metrics(&theme.mono_family, em * NativeTheme::MONO_SCALE);
        let pad = em * NativeTheme::MONO_SCALE * 0.14;
        let buffer = self.buffer();
        for run in model.prepared.styles.query(&visible).map(|i| &layout.styles[i]) {
            if run.style != Style::Code || run.range.is_empty() || in_hidden_table(model, &run.range) {
                continue;
            }
            let end = buffer.iter_at_offset(model.source.to_buffer(run.range.end));
            let mut at = buffer.iter_at_offset(model.source.to_buffer(run.range.start));
            for _ in 0..64 {
                if at >= end {
                    break;
                }
                let mut line_end = at;
                if !self.forward_display_line_end(&mut line_end) || line_end > end {
                    line_end = end;
                }
                let a = self.location(&at);
                let b = self.location(&line_end);
                // Same display line: the caret rectangles overlap vertically
                // (their heights differ with the font at each end).
                let same_line = b.y() < a.y() + a.height() && a.y() < b.y() + b.height();
                let width = if same_line { (b.x() - a.x()) as f64 } else { column_x + column_w - a.x() as f64 };
                let center = a.y() as f64 + a.height() as f64 / 2.0;
                let height = mono_ascent + mono_descent + 2.0 * pad;
                let pill = rect(a.x() as f64 - 2.0, center - height / 2.0, width + 4.0, height);
                rounded_fill(snapshot, &pill, 4.0, &theme.paper_deep);
                if line_end >= end || !self.forward_display_line(&mut line_end) {
                    break;
                }
                at = line_end;
            }
        }

        // Quote rules, one per level.
        let mut rule = theme.muted;
        rule.set_alpha(0.45);
        let quotes = visible_slice(&layout.quote_lines, &visible, |q| q.prefix.start);
        for quote in quotes.iter().filter(|q| !model.is_revealed(&q.prefix)) {
            let line = self.char_rect(model, quote.prefix.end.min(text.len()));
            for k in 0..quote.level {
                let x = column_x + quote_indent(k, em) + 0.2 * em;
                snapshot.append_color(&rule, &rect(x, line.y() as f64, 3.0, line.height() as f64));
            }
        }

        // Bullets, numbers and checkboxes in the gutter the styler left.
        let items = visible_slice(&layout.list_items, &visible, |i| i.marker.start);
        for item in items.iter().filter(|i| !model.is_revealed(&i.marker)) {
            if let (Some(done), Some(b)) = (item.task, self.task_box(model, item)) {
                self.draw_checkbox(snapshot, theme, &b, done);
                continue;
            }
            let label = if item.ordered {
                text[item.bullet.clone()].to_string()
            } else {
                ["•", "◦", "▪"][item.level.min(2)].to_string()
            };
            let anchor = self.item_anchor(model, item);
            let pango_layout = self.create_pango_layout(Some(&label));
            let (w, _) = pango_layout.pixel_size();
            let baseline = self.baseline(theme, &anchor);
            let x = anchor.x() as f64 - w as f64 - 0.45 * em;
            let y = baseline - pango_layout.baseline() as f64 / pango::SCALE as f64;
            snapshot.save();
            snapshot.translate(&graphene::Point::new(x as f32, y as f32));
            snapshot.append_layout(&pango_layout, &theme.muted);
            snapshot.restore();
        }

        // Point comments: a small accent bubble in the room the clear "[" keeps.
        for run in model.prepared.styles.query(&visible).map(|i| &layout.styles[i]) {
            let Style::Review { role: SpanRole::PointMarker, .. } = run.style else { continue };
            let unit_revealed = model.revealed.iter().any(|u| u.start == run.range.start) || model.show_all;
            if unit_revealed {
                continue;
            }
            let at = self.char_rect(model, run.range.start);
            let baseline = self.baseline(theme, &at);
            let (ascent, _) = self.metrics(&theme.body_family, em);
            let side = em * 0.5;
            let bubble = rect(at.x() as f64 + em * 0.05, baseline - ascent * 0.95, side, side * 0.8);
            rounded_fill(snapshot, &bubble, (side * 0.3) as f32, &theme.accent);
        }
    }

    fn draw_checkbox(&self, snapshot: &gtk4::Snapshot, theme: &NativeTheme, b: &graphene::Rect, done: bool) {
        let cr = snapshot.append_cairo(&b.inset_r(-2.0, -2.0));
        let (x, y, w, h) = (b.x() as f64, b.y() as f64, b.width() as f64, b.height() as f64);
        let r = 3.0;
        cr.new_sub_path();
        cr.arc(x + w - r, y + r, r, -std::f64::consts::FRAC_PI_2, 0.0);
        cr.arc(x + w - r, y + h - r, r, 0.0, std::f64::consts::FRAC_PI_2);
        cr.arc(x + r, y + h - r, r, std::f64::consts::FRAC_PI_2, std::f64::consts::PI);
        cr.arc(x + r, y + r, r, std::f64::consts::PI, 1.5 * std::f64::consts::PI);
        cr.close_path();
        let set = |c: &gdk::RGBA| cr.set_source_rgba(c.red() as f64, c.green() as f64, c.blue() as f64, c.alpha() as f64);
        if done {
            set(&theme.accent);
            let _ = cr.fill();
            cr.move_to(x + w * 0.22, y + h * 0.5);
            cr.line_to(x + w * 0.42, y + h * 0.75);
            cr.line_to(x + w * 0.8, y + h * 0.25);
            cr.set_line_width(1.6);
            set(&theme.paper);
            let _ = cr.stroke();
        } else {
            cr.set_line_width(1.2);
            set(&theme.muted);
            let _ = cr.stroke();
        }
    }
}
