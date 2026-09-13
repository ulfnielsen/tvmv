//! Typography / display settings.
//!
//! Port of `Sources/TVMVCore/AppSettings.swift`. The field set, the defaults,
//! the clamps, and above all the JSON payloads are the shared contract: the
//! same `boot.js` `applyStyle` and `editor.js` `applyStyle` read them on all
//! three platforms. Persistence is the part that differs — `UserDefaults` on
//! Apple platforms, a TOML file under `$XDG_CONFIG_HOME` here.
//!
//! # Font values are a single family, never a chain
//!
//! `boot.js` emits `JSON.stringify(cfg.monoFont) + ", monospace"`, so the value
//! becomes ONE quoted CSS family with a generic fallback appended. A
//! comma-separated value like `"JetBrains Mono, DejaVu Sans Mono"` would be
//! quoted whole, match no installed family, and silently fall back to the
//! generic. The quoting exists because an unquoted `Source Serif 4` is invalid
//! CSS (an identifier cannot start with a digit). Pick one real family; the
//! generic fallback is already handled for us.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// Matches `AppSettings.Theme`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Theme {
    #[default]
    Auto,
    Light,
    Dark,
}

/// `baseSize` clamps, matching `increaseFontSize` / `decreaseFontSize`.
const MIN_BASE_SIZE: f64 = 8.0;
const MAX_BASE_SIZE: f64 = 48.0;

fn default_body_font() -> String {
    // Same default as the Mac so a synced config means the same thing on both.
    // Not present on a stock Linux install — bundled in the Flatpak; degrades
    // to the generic serif boot.js appends when it is missing.
    "Source Serif 4".to_string()
}

fn default_mono_font() -> String {
    // The Mac defaults to Menlo, which does not exist on Linux. DejaVu Sans
    // Mono is present on effectively every desktop install. One family, per the
    // module note above.
    "DejaVu Sans Mono".to_string()
}

fn default_base_size() -> f64 {
    16.0
}
fn default_measure() -> f64 {
    80.0
}
fn default_show_outline() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "snake_case")]
pub struct Settings {
    pub body_font: String,
    pub mono_font: String,
    pub base_size: f64,
    pub measure: f64,
    pub full_width: bool,
    pub theme: Theme,
    pub show_outline: bool,
    /// Chosen in Settings; empty means "no override, use the built-in theme".
    pub custom_css_path: String,
    pub editor_pane_width: f64,
    /// Editor-pane font family. Empty means "same as the code font".
    pub editor_font: String,
    /// Editor-pane font size in points. 0 means "same as the base size".
    pub editor_font_size: f64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            body_font: default_body_font(),
            mono_font: default_mono_font(),
            base_size: default_base_size(),
            measure: default_measure(),
            full_width: false,
            theme: Theme::default(),
            show_outline: default_show_outline(),
            custom_css_path: String::new(),
            editor_pane_width: 0.0,
            editor_font: String::new(),
            editor_font_size: 0.0,
        }
    }
}

/// The preview payload, matching `AppSettings.styleJSON`.
#[derive(Serialize)]
struct PreviewStyle<'a> {
    #[serde(rename = "bodyFont")]
    body_font: &'a str,
    #[serde(rename = "monoFont")]
    mono_font: &'a str,
    #[serde(rename = "baseSize")]
    base_size: f64,
    measure: f64,
    #[serde(rename = "fullWidth")]
    full_width: bool,
    theme: &'a str,
}

/// The editor payload, matching `AppSettings.editorStyleJSON`.
#[derive(Serialize)]
struct EditorStyle<'a> {
    #[serde(rename = "monoFont")]
    mono_font: &'a str,
    #[serde(rename = "baseSize")]
    base_size: f64,
    theme: &'a str,
}

impl Settings {
    pub fn increase_font_size(&mut self) {
        self.base_size = (self.base_size + 1.0).min(MAX_BASE_SIZE);
    }

    pub fn decrease_font_size(&mut self) {
        self.base_size = (self.base_size - 1.0).max(MIN_BASE_SIZE);
    }

    /// Resolve `Theme::Auto` against the system appearance.
    ///
    /// The caller supplies the system preference rather than this module
    /// querying it, so the payloads stay unit-testable with no D-Bus. The
    /// portal query (`org.freedesktop.appearance` `color-scheme`) lives in the
    /// shell — that is also what makes it work on KDE and XFCE, not just GNOME.
    pub fn resolved_theme(&self, system_prefers_dark: bool) -> &'static str {
        match self.theme {
            Theme::Light => "light",
            Theme::Dark => "dark",
            Theme::Auto if system_prefers_dark => "dark",
            Theme::Auto => "light",
        }
    }

    /// JSON payload for `boot.js` `applyStyle`.
    ///
    /// `baseSize` and `measure` must stay JSON *numbers*: boot.js branches on
    /// `typeof === "number"` to append `px` / `ch`, and a string would be passed
    /// through raw as an invalid CSS length.
    pub fn style_json(&self, system_prefers_dark: bool) -> String {
        let style = PreviewStyle {
            body_font: &self.body_font,
            mono_font: &self.mono_font,
            base_size: self.base_size,
            measure: self.measure,
            full_width: self.full_width,
            theme: self.resolved_theme(system_prefers_dark),
        };
        serde_json::to_string(&style).unwrap_or_else(|_| "{}".to_string())
    }

    /// JSON payload for `editor.js` `applyStyle`. Dedicated editor overrides
    /// win when set; otherwise the editor follows the code font / base size.
    pub fn editor_style_json(&self, system_prefers_dark: bool) -> String {
        let style = EditorStyle {
            mono_font: if self.editor_font.is_empty() { &self.mono_font } else { &self.editor_font },
            base_size: if self.editor_font_size > 0.0 { self.editor_font_size } else { self.base_size },
            theme: self.resolved_theme(system_prefers_dark),
        };
        serde_json::to_string(&style).unwrap_or_else(|_| "{}".to_string())
    }

    /// The custom-CSS file chosen in Settings, or `None` for the built-in
    /// theme. Nothing is loaded unless the user explicitly picked a file.
    pub fn custom_css_path(&self) -> Option<PathBuf> {
        if self.custom_css_path.is_empty() {
            return None;
        }
        Some(expand_tilde(&self.custom_css_path))
    }

    pub fn load_from(path: &Path) -> Result<Self, SettingsError> {
        let text = std::fs::read_to_string(path).map_err(SettingsError::Io)?;
        toml::from_str(&text).map_err(|e| SettingsError::Parse(e.to_string()))
    }

    /// Load from the standard location, falling back to defaults.
    ///
    /// A malformed file never blocks startup and is never rewritten from here —
    /// it is left on disk for the user to fix, and the reason is returned so the
    /// shell can surface it once.
    pub fn load() -> (Self, Option<SettingsError>) {
        let path = config_path();
        match Self::load_from(&path) {
            Ok(settings) => (settings, None),
            // No file yet is the normal first-run case, not an error worth showing.
            Err(SettingsError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => {
                (Self::default(), None)
            }
            Err(e) => (Self::default(), Some(e)),
        }
    }

    pub fn save(&self) -> Result<(), SettingsError> {
        self.save_to(&config_path())
    }

    /// Write atomically: a crash mid-write must not leave a truncated config
    /// that silently resets every preference on next launch.
    pub fn save_to(&self, path: &Path) -> Result<(), SettingsError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(SettingsError::Io)?;
        }
        let text =
            toml::to_string_pretty(self).map_err(|e| SettingsError::Serialize(e.to_string()))?;

        let temp = path.with_extension("toml.tmp");
        std::fs::write(&temp, text).map_err(SettingsError::Io)?;
        std::fs::rename(&temp, path).map_err(SettingsError::Io)
    }
}

/// `$XDG_CONFIG_HOME/tvmv/settings.toml`, falling back to `~/.config`.
pub fn config_path() -> PathBuf {
    config_dir().join("tvmv").join("settings.toml")
}

fn config_dir() -> PathBuf {
    if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME")
        && !xdg.is_empty()
    {
        return PathBuf::from(xdg);
    }
    match std::env::var_os("HOME") {
        Some(home) => PathBuf::from(home).join(".config"),
        None => PathBuf::from(".config"),
    }
}

fn expand_tilde(path: &str) -> PathBuf {
    if path == "~" {
        return std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(path));
    }
    if let Some(rest) = path.strip_prefix("~/")
        && let Some(home) = std::env::var_os("HOME")
    {
        return PathBuf::from(home).join(rest);
    }
    PathBuf::from(path)
}

#[derive(Debug)]
pub enum SettingsError {
    Io(std::io::Error),
    Parse(String),
    Serialize(String),
}

impl std::fmt::Display for SettingsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "{e}"),
            Self::Parse(e) => write!(f, "malformed settings file: {e}"),
            Self::Serialize(e) => write!(f, "could not serialize settings: {e}"),
        }
    }
}

impl std::error::Error for SettingsError {}
