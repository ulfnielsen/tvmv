//! Window chrome tinted to the document.
//!
//! Port of the Mac app's `chromeColor`: read the rendered page's background,
//! lighten it, and paint the window with it, so the frame around a document
//! belongs to that document rather than to the desktop theme. It is what makes
//! TVMV look like TVMV on any platform, and it is what makes a custom user
//! stylesheet tint the whole window rather than just the text area.
//!
//! `theme::paper` covers the moment before the page exists; this replaces it
//! once the page has actually rendered, which is why custom CSS works here and
//! not there.

use gtk4::CssProvider;

/// Straight RGBA, components 0..1. Mirrors `RGBAColor.swift`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rgba {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub alpha: f64,
}

impl Rgba {
    /// Blend `fraction` of `other` into this colour.
    pub fn blended(self, fraction: f64, of: Rgba) -> Rgba {
        let mix = |a: f64, b: f64| a + (b - a) * fraction;
        Rgba {
            red: mix(self.red, of.red),
            green: mix(self.green, of.green),
            blue: mix(self.blue, of.blue),
            alpha: self.alpha,
        }
    }

    pub const WHITE: Rgba = Rgba { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 };

    pub fn to_hex(self) -> String {
        let c = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
        format!("#{:02x}{:02x}{:02x}", c(self.red), c(self.green), c(self.blue))
    }
}

/// How much white to mix into the page background. Matches the Mac app so the
/// two platforms tint identically for the same document.
const LIGHTEN_FRACTION: f64 = 0.16;

/// A background this transparent means the page has not painted yet; tinting
/// from it would flash an unrelated colour.
const MIN_ALPHA: f64 = 0.05;

/// Compute the chrome tint from a CSS colour string, or `None` if it is not
/// usable yet.
pub fn tint_from_page_background(css: &str) -> Option<Rgba> {
    let base = parse_css_color(css)?;
    if base.alpha <= MIN_ALPHA {
        return None;
    }
    Some(base.blended(LIGHTEN_FRACTION, Rgba::WHITE))
}

/// Parse `rgb(r, g, b)` / `rgba(r, g, b, a)`.
///
/// Deliberately the same crude approach as the Swift side — split on anything
/// that is not a digit or a dot and take the numbers — so both platforms accept
/// and reject exactly the same strings. `getComputedStyle` only ever returns
/// these two forms.
pub fn parse_css_color(s: &str) -> Option<Rgba> {
    let numbers: Vec<f64> = s
        .split(|c: char| !c.is_ascii_digit() && c != '.')
        .filter(|part| !part.is_empty())
        .filter_map(|part| part.parse::<f64>().ok())
        .collect();

    if numbers.len() < 3 {
        return None;
    }
    Some(Rgba {
        red: numbers[0] / 255.0,
        green: numbers[1] / 255.0,
        blue: numbers[2] / 255.0,
        alpha: if numbers.len() >= 4 { numbers[3] } else { 1.0 },
    })
}

/// A CSS class unique to one window, so each window's tint is scoped to it.
///
/// GTK4 providers attach to the *display*, not to a widget
/// (`WidgetExt::style_context` is deprecated since 4.10), so two windows showing
/// differently-themed documents would otherwise overwrite each other's tint.
pub fn scope_class(serial: usize) -> String {
    format!("tvmv-win-{serial}")
}

/// Separator strength for the chrome's dividing rules.
///
/// Derived from the foreground colour rather than a fixed grey, so it stays
/// legible against both the light and dark themes and against a custom
/// stylesheet's background. One constant for every rule, so the toolbar's
/// underline and the sidebar's edge are visibly the same line.
const SEPARATOR: &str = "alpha(currentColor, 0.12)";

/// Paint one window's chrome with `tint`.
///
/// `scope` is that window's unique class, from [`scope_class`].
pub fn apply_tint(scope: &str, tint: Rgba, provider: &CssProvider) {
    let hex = tint.to_hex();
    provider.load_from_string(&format!(
        "window.{scope} {{ background-color: {hex}; }}\n\
         .{scope} .tvmv-sidebar,\n\
         .{scope} .tvmv-findbar,\n\
         .{scope} .tvmv-toolbar {{ background-color: {hex}; }}\n\
         .{scope} .tvmv-toolbar {{ border-bottom: 1px solid {SEPARATOR}; }}\n\
         .{scope} .tvmv-sidebar {{ border-right: 1px solid {SEPARATOR}; }}"
    ));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    #[test]
    fn parses_rgb() {
        let c = parse_css_color("rgb(251, 248, 242)").unwrap();
        assert!(approx(c.red, 251.0 / 255.0));
        assert!(approx(c.green, 248.0 / 255.0));
        assert!(approx(c.blue, 242.0 / 255.0));
        assert!(approx(c.alpha, 1.0));
    }

    #[test]
    fn parses_rgba_with_fractional_alpha() {
        let c = parse_css_color("rgba(24, 20, 16, 0.5)").unwrap();
        assert!(approx(c.alpha, 0.5));
        assert!(approx(c.red, 24.0 / 255.0));
    }

    #[test]
    fn rejects_unparseable() {
        assert!(parse_css_color("transparent").is_none());
        assert!(parse_css_color("").is_none());
        assert!(parse_css_color("rgb(1, 2)").is_none());
    }

    /// A fully transparent body is what `getComputedStyle` reports before the
    /// page paints; tinting from it would flash black.
    #[test]
    fn transparent_background_yields_no_tint() {
        assert!(tint_from_page_background("rgba(0, 0, 0, 0)").is_none());
        assert!(tint_from_page_background("rgba(0, 0, 0, 0.01)").is_none());
    }

    #[test]
    fn tint_lightens_toward_white() {
        let tint = tint_from_page_background("rgb(251, 248, 242)").unwrap();
        let base = parse_css_color("rgb(251, 248, 242)").unwrap();
        assert!(tint.red > base.red && tint.green > base.green && tint.blue > base.blue);
        assert!(tint.red <= 1.0 && tint.green <= 1.0 && tint.blue <= 1.0);
    }

    /// The dark theme must lighten too — the point is contrast against the page,
    /// not "make it brighter than mid-grey".
    #[test]
    fn dark_page_also_lightens() {
        let tint = tint_from_page_background("rgb(24, 20, 16)").unwrap();
        assert!(tint.red > 24.0 / 255.0);
        // 16% of the way toward 255: r 24->61 (0x3d), g 20->58 (0x3a), b 16->54 (0x36).
        assert_eq!(tint.to_hex(), "#3d3a36");
    }

    #[test]
    fn hex_roundtrip() {
        assert_eq!(Rgba::WHITE.to_hex(), "#ffffff");
        assert_eq!(parse_css_color("rgb(0,0,0)").unwrap().to_hex(), "#000000");
        assert_eq!(parse_css_color("rgb(251,248,242)").unwrap().to_hex(), "#fbf8f2");
    }

    #[test]
    fn blend_endpoints() {
        let black = parse_css_color("rgb(0,0,0)").unwrap();
        assert_eq!(black.blended(0.0, Rgba::WHITE).to_hex(), "#000000");
        assert_eq!(black.blended(1.0, Rgba::WHITE).to_hex(), "#ffffff");
    }

    /// Alpha is carried through the blend unchanged, as on the Mac.
    #[test]
    fn blend_preserves_alpha() {
        let c = parse_css_color("rgba(10, 20, 30, 0.4)").unwrap();
        assert!(approx(c.blended(0.5, Rgba::WHITE).alpha, 0.4));
    }
}
