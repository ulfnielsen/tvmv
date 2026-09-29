//! Reading position and one explicit bookmark per document, kept outside the Markdown file.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Default, Serialize, Deserialize)]
pub struct ReadingState {
    pub position: f64,
    pub bookmark: Option<f64>,
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
