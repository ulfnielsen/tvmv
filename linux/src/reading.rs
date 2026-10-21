//! Reading position and one explicit bookmark per document, kept outside the Markdown file.
//!
//! The native view stores both as source byte offsets, which survive edits
//! and resizes. Older builds stored scroll fractions (`position`,
//! `bookmark`); a fraction is read until an offset replaces it, as on macOS
//! (`ReadingPositionStore.swift`).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Default, Serialize, Deserialize)]
pub struct ReadingState {
    /// Legacy scroll fraction, 0…1; also kept current for the web preview.
    pub position: f64,
    pub bookmark: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offset: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bookmark_offset: Option<usize>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Position {
    Offset(usize),
    /// Legacy scroll fraction, 0…1.
    Fraction(f64),
}

impl ReadingState {
    pub fn reading_position(&self) -> Option<Position> {
        match self.offset {
            Some(o) => Some(Position::Offset(o)),
            None if self.position > 0.0 => Some(Position::Fraction(self.position)),
            None => None,
        }
    }

    pub fn bookmark_position(&self) -> Option<Position> {
        self.bookmark_offset.map(Position::Offset).or(self.bookmark.map(Position::Fraction))
    }

    /// Remove the bookmark: the offset and any legacy fraction behind it.
    pub fn clear_bookmark(&mut self) {
        self.bookmark = None;
        self.bookmark_offset = None;
    }
}

fn state_file() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state"))
        })?;
    Some(base.join("tvmv/reading.json"))
}

fn key(path: &Path) -> String {
    path.canonicalize()
        .unwrap_or_else(|_| path.to_path_buf())
        .to_string_lossy()
        .into_owned()
}

fn all() -> BTreeMap<String, ReadingState> {
    let Some(file) = state_file() else {
        return BTreeMap::new();
    };
    std::fs::read(file)
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
        .unwrap_or_default()
}

pub fn load(path: &Path) -> ReadingState {
    all().get(&key(path)).copied().unwrap_or_default()
}

pub fn save(path: &Path, state: ReadingState) {
    let Some(file) = state_file() else { return };
    let mut entries = all();
    entries.insert(key(path), state);
    let Some(parent) = file.parent() else { return };
    if std::fs::create_dir_all(parent).is_err() {
        return;
    }
    let temp = file.with_extension("json.tmp");
    if let Ok(data) = serde_json::to_vec(&entries) {
        if std::fs::write(&temp, data).is_ok() {
            let _ = std::fs::rename(&temp, file);
        }
    }
}
