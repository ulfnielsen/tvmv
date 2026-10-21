//! Fonts, colors and measure for the native view: the paper & ink palette
//! from app.css. A port of `Sources/tvmv/NativeTheme.swift`; the colors must
//! stay the same values.

use gtk4::gdk::RGBA;

use crate::settings::Settings;

#[derive(Clone, Debug, PartialEq)]
pub struct NativeTheme {
    pub body_family: String,
    pub mono_family: String,
    /// Body text size in CSS pixels (app.css `--tvmv-base`).
    pub size: f64,
    /// Column width in "0" widths; ignored when `full_width`.
    pub measure: f64,
    pub full_width: bool,
    pub dark: bool,
    pub ink: RGBA,
    pub ink_soft: RGBA,
    pub muted: RGBA,
    pub accent: RGBA,
    pub paper: RGBA,
    pub paper_deep: RGBA,
    /// Review markup: a commented range's background, inserted and deleted text.
    pub review_highlight: RGBA,
    pub review_insert: RGBA,
    pub review_delete: RGBA,
    /// Minimum horizontal padding either side of the column (app.css --tvmv-pad).
    pub padding: f64,
}

fn hex(v: u32, alpha: f32) -> RGBA {
    let c = |shift: u32| ((v >> shift) & 0xFF) as f32 / 255.0;
    RGBA::new(c(16), c(8), c(0), alpha)
}

/// `#rrggbb` or `rgba(…)` for CSS.
pub fn css_color(c: &RGBA) -> String {
    format!(
        "rgba({}, {}, {}, {})",
        (c.red() * 255.0).round(),
        (c.green() * 255.0).round(),
        (c.blue() * 255.0).round(),
        c.alpha()
    )
}

impl NativeTheme {
    pub fn new(body_family: &str, mono_family: &str, size: f64, measure: f64, full_width: bool, dark: bool) -> Self {
        let (paper, paper_deep, ink, ink_soft, muted, accent, highlight, insert, delete) = if dark {
            (
                hex(0x181410, 1.0),
                hex(0x221C16, 1.0),
                hex(0xECE3D3, 1.0),
                hex(0xCBB89B, 1.0),
                hex(0x9C876A, 1.0),
                hex(0xE2693B, 1.0),
                hex(0x8A6D10, 0.55),
                hex(0x7FC48A, 1.0),
                hex(0xEF8A80, 1.0),
            )
        } else {
            (
                hex(0xFBF8F2, 1.0),
                hex(0xF4EFE3, 1.0),
                hex(0x2A1810, 1.0),
                hex(0x5A3D2A, 1.0),
                hex(0x8A7359, 1.0),
                hex(0xB83F12, 1.0),
                hex(0xFFE27A, 0.6),
                hex(0x2E7D32, 1.0),
                hex(0xB3261E, 1.0),
            )
        };
        NativeTheme {
            body_family: body_family.to_string(),
            mono_family: mono_family.to_string(),
            size,
            measure,
            full_width,
            dark,
            ink,
            ink_soft,
            muted,
            accent,
            paper,
            paper_deep,
            review_highlight: highlight,
            review_insert: insert,
            review_delete: delete,
            padding: 68.0,
        }
    }

    /// The theme for the current settings. `dark` is the resolved appearance.
    pub fn from_settings(settings: &Settings, dark: bool) -> Self {
        Self::new(
            &settings.body_font,
            &settings.mono_font,
            settings.base_size,
            settings.measure,
            settings.full_width,
            dark,
        )
    }

    /// The em, in pixels.
    pub fn em(&self) -> f64 {
        self.size
    }

    /// app.css heading scale: h1 2.0em … h6 0.85em.
    pub fn heading_scale(level: usize) -> f64 {
        [2.0, 1.5, 1.28, 1.1, 0.95, 0.85][level.clamp(1, 6) - 1]
    }

    /// The code font is set a little smaller than the body, as in app.css.
    pub const MONO_SCALE: f64 = 0.86;

    /// Body line height (app.css 1.7).
    pub const LINE_HEIGHT: f32 = 1.7;

    /// The view's stylesheet: base font, paper, ink, caret and selection,
    /// and a table grid's rules, header and cells.
    pub fn css(&self) -> String {
        let mut selection = self.accent;
        selection.set_alpha(0.18);
        let mut rule = self.muted;
        rule.set_alpha(0.35);
        format!(
            "textview.tvmv-native {{ font-family: \"{body}\", serif; font-size: {size}px; line-height: {lh}; color: {ink}; }}\n\
             textview.tvmv-native text {{ background-color: {paper}; color: {ink}; caret-color: {ink}; }}\n\
             textview.tvmv-native border {{ background-color: {paper}; }}\n\
             textview.tvmv-native text selection {{ background-color: {selection}; color: {ink}; }}\n\
             grid.tvmv-table-grid {{ border-top: 1px solid {rule}; border-left: 1px solid {rule}; }}\n\
             .tvmv-table-tools {{ margin-top: 6px; }}\n\
             .tvmv-table-tools button {{ font-family: sans-serif; font-size: 11px; min-height: 22px; padding: 0 6px; }}\n\
             textview.tvmv-native.tvmv-cell {{ line-height: 1.3; background-color: transparent; \
               border-right: 1px solid {rule}; border-bottom: 1px solid {rule}; }}\n\
             textview.tvmv-native.tvmv-cell text {{ background-color: transparent; }}\n\
             textview.tvmv-native.tvmv-cell-header {{ background-color: {deep}; font-weight: bold; }}\n\
             .tvmv-card {{ background-color: {deep}; border: 1px solid {rule}; border-radius: 8px; padding: 10px 12px; \
               font-family: sans-serif; font-size: 12px; line-height: 1.3; }}\n\
             .tvmv-card.focused {{ border: 2px solid {accent}; padding: 9px 11px; }}\n\
             .tvmv-card label {{ color: {soft}; }}\n\
             .tvmv-card label.tvmv-card-heading {{ font-size: 10px; font-weight: 600; letter-spacing: 0.6px; color: {muted}; }}\n\
             .tvmv-card label.tvmv-card-heading.problem {{ color: {accent}; }}\n\
             .tvmv-card label.tvmv-card-change {{ font-weight: 500; color: {ink}; }}\n\
             .tvmv-card label.error {{ color: #c01c28; }}\n",
            body = self.body_family.replace('"', ""),
            size = self.size,
            lh = Self::LINE_HEIGHT,
            paper = css_color(&self.paper),
            ink = css_color(&self.ink),
            selection = css_color(&selection),
            rule = css_color(&rule),
            deep = css_color(&self.paper_deep),
            accent = css_color(&self.accent),
            soft = css_color(&self.ink_soft),
            muted = css_color(&self.muted),
        )
    }
}
