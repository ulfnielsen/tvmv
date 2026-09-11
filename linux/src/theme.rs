//! Reads theme colours out of the shared stylesheet.
//!
//! The GTK side needs the page's paper colour before the page exists: WebKitGTK
//! paints a web view opaque **white** by default, and the GTK window uses the
//! desktop theme's background. Against the warm `#FBF8F2` paper both read as a
//! cold flash — on load, on overscroll, and while resizing.
//!
//! The value is parsed out of `app.css` rather than copied into Rust, so the
//! shell cannot drift from the theme the way a duplicated constant would. The
//! fallbacks below are only for a stylesheet that cannot be read at all.
//!
//! NOTE: this is the *built-in* theme's colour. Custom user CSS can override
//! `--paper`, and the Mac app handles that by computing `chromeColor` from the
//! rendered page. Task 9 brings that here; until then a custom stylesheet with a
//! very different background will still flash.

use std::path::Path;

/// `--paper` from `:root` in `app.css`.
const FALLBACK_LIGHT_HEX: &str = "#FBF8F2";
/// `--paper` from `html[data-theme="dark"]`.
const FALLBACK_DARK_HEX: &str = "#181410";

/// Kept as hex and parsed through the same path as the stylesheet: writing the
/// components out by hand invites rounding that silently differs from the real
/// value (0.984 is not 251/255), which is exactly what the tests caught.
fn fallback(dark: bool) -> (f64, f64, f64) {
    let hex = if dark { FALLBACK_DARK_HEX } else { FALLBACK_LIGHT_HEX };
    parse_hex(hex).expect("built-in fallback colours are valid hex")
}

/// The built-in paper colour without needing a web directory.
///
/// The thumbnailer has no window and no assets on hand, and its card must still
/// be the same paper as the app's.
pub fn paper_for(dark: bool) -> (f64, f64, f64) {
    fallback(dark)
}

/// The page background for the given theme, as linear 0..1 RGB.
pub fn paper(web_dir: &Path, dark: bool) -> (f64, f64, f64) {
    let Ok(css) = std::fs::read_to_string(web_dir.join("app.css")) else {
        return fallback(dark);
    };
    parse_paper(&css, dark).unwrap_or_else(|| fallback(dark))
}

/// Find the `--paper:` declaration inside the relevant block.
fn parse_paper(css: &str, dark: bool) -> Option<(f64, f64, f64)> {
    let selector = if dark { "html[data-theme=\"dark\"]" } else { ":root" };
    let block_start = css.find(selector)? + selector.len();
    let rest = &css[block_start..];
    let block_end = rest.find('}')?;
    let block = &rest[..block_end];

    let decl_start = block.find("--paper:")? + "--paper:".len();
    let decl = &block[decl_start..];
    let value = decl.split(';').next()?.trim();
    parse_hex(value)
}

fn parse_hex(value: &str) -> Option<(f64, f64, f64)> {
    let hex = value.strip_prefix('#')?;
    if hex.len() < 6 {
        return None;
    }
    let component = |i: usize| u8::from_str_radix(&hex[i..i + 2], 16).ok().map(|v| v as f64 / 255.0);
    Some((component(0)?, component(2)?, component(4)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_both_themes_from_the_real_stylesheet() {
        // Whichever location the shared web layer is in (see Task 1).
        let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
        let dir = ["web", "Sources/TVMVCore/Resources/web"]
            .iter()
            .map(|c| root.join(c))
            .find(|p| p.join("app.css").is_file())
            .expect("shared web layer found");

        // Parsed, not fallen back to: assert against app.css's actual values.
        assert_eq!(paper(&dir, false), parse_hex("#FBF8F2").unwrap());
        assert_eq!(paper(&dir, true), parse_hex("#181410").unwrap());
    }

    #[test]
    fn falls_back_when_the_stylesheet_is_missing() {
        let dir = std::path::Path::new("/nonexistent-tvmv-web");
        assert_eq!(paper(dir, false), fallback(false));
        assert_eq!(paper(dir, true), fallback(true));
    }

    #[test]
    fn parses_hex() {
        assert_eq!(parse_hex("#FFFFFF"), Some((1.0, 1.0, 1.0)));
        assert_eq!(parse_hex("#000000"), Some((0.0, 0.0, 0.0)));
        assert_eq!(parse_hex("not-a-colour"), None);
    }
}
