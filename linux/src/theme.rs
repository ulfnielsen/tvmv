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

use crate::assets::{AssetRouter, SCHEME, WebSource};

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
///
/// Reads `app.css` through the same router the web view does, so the embedded
/// stylesheet and an overridden directory both answer here — a colour parsed
/// from a stylesheet the page is not actually using would be worse than the
/// fallback.
pub fn paper(source: &WebSource, dark: bool) -> (f64, f64, f64) {
    let router = AssetRouter::new(source.clone());
    let Ok(asset) = router.resolve(&format!("{SCHEME}://app/app.css")) else {
        return fallback(dark);
    };
    let css = match asset {
        crate::assets::Asset::Bytes(bytes) => String::from_utf8_lossy(bytes).into_owned(),
        crate::assets::Asset::File(path) => match std::fs::read_to_string(&path) {
            Ok(css) => css,
            Err(_) => return fallback(dark),
        },
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

    /// The embedded stylesheet is what the app actually serves, so it is what
    /// the pre-render colour has to be read from.
    #[test]
    fn parses_both_themes_from_the_embedded_stylesheet() {
        // Parsed, not fallen back to: assert against app.css's actual values.
        assert_eq!(paper(&WebSource::Embedded, false), parse_hex("#FBF8F2").unwrap());
        assert_eq!(paper(&WebSource::Embedded, true), parse_hex("#181410").unwrap());
    }

    /// A directory source must agree with the embedded one — same stylesheet,
    /// same colour, whichever way it is reached.
    #[test]
    fn a_directory_source_gives_the_same_colours() {
        let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
        let dir = ["web", "Sources/TVMVCore/Resources/web"]
            .iter()
            .map(|c| root.join(c))
            .find(|p| p.join("app.css").is_file())
            .expect("shared web layer found");

        for dark in [false, true] {
            assert_eq!(paper(&WebSource::Directory(dir.clone()), dark), paper(&WebSource::Embedded, dark));
        }
    }

    #[test]
    fn falls_back_when_the_stylesheet_is_missing() {
        let dir = WebSource::Directory("/nonexistent-tvmv-web".into());
        assert_eq!(paper(&dir, false), fallback(false));
        assert_eq!(paper(&dir, true), fallback(true));
    }

    #[test]
    fn parses_hex() {
        assert_eq!(parse_hex("#FFFFFF"), Some((1.0, 1.0, 1.0)));
        assert_eq!(parse_hex("#000000"), Some((0.0, 0.0, 0.0)));
        assert_eq!(parse_hex("not-a-colour"), None);
    }
}
