//! Settings tests, including contract tests that read the shared web layer
//! directly rather than trusting a transcription of it.

use std::path::PathBuf;

use tvmv::settings::{Settings, Theme};

/// The shared web layer. Task 1 promotes it to `/web`; until then it lives
/// under the SwiftPM resource directory. Try both so this suite survives the
/// move without an edit.
fn web_dir() -> PathBuf {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    for candidate in ["web", "Sources/TVMVCore/Resources/web"] {
        let path = root.join(candidate);
        if path.join("boot.js").exists() {
            return path;
        }
    }
    panic!("shared web layer not found — looked for web/ and Sources/TVMVCore/Resources/web/");
}

fn json(settings: &Settings, dark: bool) -> serde_json::Value {
    serde_json::from_str(&settings.style_json(dark)).expect("style_json emits valid JSON")
}

// --- defaults --------------------------------------------------------------

#[test]
fn defaults_match_the_mac() {
    let s = Settings::default();
    assert_eq!(s.body_font, "Source Serif 4");
    assert_eq!(s.base_size, 16.0);
    assert_eq!(s.measure, 80.0);
    assert!(!s.full_width);
    assert_eq!(s.theme, Theme::Auto);
    assert!(s.show_outline);
    assert_eq!(s.custom_css_path, "");
    assert_eq!(s.editor_pane_width, 0.0);
    assert_eq!(s.editor_font, "");
    assert_eq!(s.editor_font_size, 0.0);
}

/// The Mac's "Menlo" does not exist on Linux; the default must name a family
/// that is actually present, and must be a single family (see below).
#[test]
fn default_mono_font_is_a_single_linux_family() {
    let s = Settings::default();
    assert_eq!(s.mono_font, "DejaVu Sans Mono");
    assert!(!s.mono_font.contains(','), "font values are one family, not a chain");
}

// --- the applyStyle contract ----------------------------------------------

/// Every key emitted must be a key boot.js actually reads. Asserted against the
/// shared source so a rename on either side fails here.
#[test]
fn preview_style_keys_exist_in_boot_js() {
    let boot = std::fs::read_to_string(web_dir().join("boot.js")).expect("boot.js is readable");
    for key in ["bodyFont", "monoFont", "baseSize", "measure", "fullWidth", "theme"] {
        assert!(boot.contains(&format!("cfg.{key}")), "boot.js does not read cfg.{key}");
    }
    let emitted = json(&Settings::default(), false);
    let object = emitted.as_object().expect("style_json is a JSON object");
    assert_eq!(object.len(), 6, "unexpected key set: {emitted}");
}

#[test]
fn editor_style_keys_exist_in_editor_js() {
    let editor = std::fs::read_to_string(web_dir().join("editor.js")).expect("editor.js is readable");
    for key in ["monoFont", "baseSize", "theme"] {
        assert!(editor.contains(&format!("cfg.{key}")), "editor.js does not read cfg.{key}");
    }
    let emitted: serde_json::Value =
        serde_json::from_str(&Settings::default().editor_style_json(false)).unwrap();
    assert_eq!(emitted.as_object().unwrap().len(), 3, "unexpected key set: {emitted}");
}

/// boot.js branches on `typeof cfg.baseSize === "number"` to append px/ch. A
/// string would be passed through as an invalid CSS length and silently ignored.
#[test]
fn sizes_serialize_as_json_numbers() {
    let v = json(&Settings::default(), false);
    assert!(v["baseSize"].is_number(), "baseSize must be a number: {v}");
    assert!(v["measure"].is_number(), "measure must be a number: {v}");
    assert!(v["fullWidth"].is_boolean(), "fullWidth must be a bool: {v}");
    assert!(v["theme"].is_string());
}

// --- theme resolution ------------------------------------------------------

#[test]
fn theme_resolution() {
    // Auto is the default.
    let mut s = Settings::default();
    assert_eq!(s.theme, Theme::Auto);
    assert_eq!(s.resolved_theme(false), "light");
    assert_eq!(s.resolved_theme(true), "dark");

    // An explicit choice ignores the system preference.
    s.theme = Theme::Light;
    assert_eq!(s.resolved_theme(true), "light");
    s.theme = Theme::Dark;
    assert_eq!(s.resolved_theme(false), "dark");
}

#[test]
fn resolved_theme_reaches_both_payloads() {
    let s = Settings::default(); // auto
    assert_eq!(json(&s, true)["theme"], "dark");
    let editor: serde_json::Value = serde_json::from_str(&s.editor_style_json(true)).unwrap();
    assert_eq!(editor["theme"], "dark");
}

// --- editor overrides ------------------------------------------------------

#[test]
fn editor_falls_back_to_code_font_and_base_size() {
    let s = Settings::default();
    let v: serde_json::Value = serde_json::from_str(&s.editor_style_json(false)).unwrap();
    assert_eq!(v["monoFont"], s.mono_font.as_str());
    assert_eq!(v["baseSize"], s.base_size);
}

#[test]
fn editor_overrides_win_when_set() {
    let mut s = Settings {
        editor_font: "Fira Code".into(),
        editor_font_size: 13.0,
        ..Settings::default()
    };
    let v: serde_json::Value = serde_json::from_str(&s.editor_style_json(false)).unwrap();
    assert_eq!(v["monoFont"], "Fira Code");
    assert_eq!(v["baseSize"], 13.0);

    // Zero means "follow the base size", not "13px of nothing".
    s.editor_font_size = 0.0;
    let v: serde_json::Value = serde_json::from_str(&s.editor_style_json(false)).unwrap();
    assert_eq!(v["baseSize"], s.base_size);
}

// --- font size clamps ------------------------------------------------------

#[test]
fn font_size_clamps() {
    let mut s = Settings::default();
    for _ in 0..100 {
        s.increase_font_size();
    }
    assert_eq!(s.base_size, 48.0);
    for _ in 0..100 {
        s.decrease_font_size();
    }
    assert_eq!(s.base_size, 8.0);
}

// --- persistence -----------------------------------------------------------

fn temp_path(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("tvmv-settings-tests");
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

#[test]
fn round_trips_through_toml() {
    let path = temp_path("roundtrip.toml");
    let s = Settings {
        body_font: "Iosevka Etoile".into(),
        base_size: 18.0,
        theme: Theme::Dark,
        full_width: true,
        custom_css_path: "~/themes/comic.css".into(),
        ..Settings::default()
    };

    s.save_to(&path).expect("save succeeds");
    assert_eq!(Settings::load_from(&path).expect("load succeeds"), s);
    let _ = std::fs::remove_file(&path);
}

/// A config written by an older build, missing keys a newer one added, must
/// load with defaults rather than failing and resetting everything.
#[test]
fn missing_keys_fall_back_to_defaults() {
    let path = temp_path("partial.toml");
    std::fs::write(&path, "base_size = 20.0\ntheme = \"dark\"\n").unwrap();

    let s = Settings::load_from(&path).expect("partial config loads");
    assert_eq!(s.base_size, 20.0);
    assert_eq!(s.theme, Theme::Dark);
    assert_eq!(s.body_font, Settings::default().body_font);
    assert_eq!(s.measure, 80.0);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn malformed_config_is_reported_not_silently_replaced() {
    let path = temp_path("malformed.toml");
    std::fs::write(&path, "this is not = = toml").unwrap();

    assert!(Settings::load_from(&path).is_err());
    // The bad file is left alone for the user to fix.
    assert!(path.exists());
    let _ = std::fs::remove_file(&path);
}

#[test]
fn save_leaves_no_temp_file_behind() {
    let path = temp_path("atomic.toml");
    Settings::default().save_to(&path).unwrap();
    assert!(path.exists());
    assert!(!path.with_extension("toml.tmp").exists(), "temp file leaked");
    let _ = std::fs::remove_file(&path);
}

// --- custom CSS path -------------------------------------------------------

#[test]
fn custom_css_path_is_none_until_chosen() {
    assert!(Settings::default().custom_css_path().is_none());
}

#[test]
fn custom_css_path_expands_tilde() {
    let mut s = Settings { custom_css_path: "~/themes/comic.css".into(), ..Settings::default() };
    let resolved = s.custom_css_path().expect("path resolves");
    assert!(!resolved.to_string_lossy().starts_with('~'), "tilde survived: {resolved:?}");
    assert!(resolved.ends_with("themes/comic.css"));

    // An absolute path is untouched.
    s.custom_css_path = "/etc/tvmv/theme.css".into();
    assert_eq!(s.custom_css_path().unwrap(), PathBuf::from("/etc/tvmv/theme.css"));
}
