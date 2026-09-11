//! Locates the shared `web/` directory at runtime.
//!
//! Mirrors the layered resolution in `Sources/TVMVCore/ResourceLocator.swift`,
//! for the same reason: the answer differs between an installed app and a
//! working copy, and failing over to a clear "not found" beats a blank window.
//!
//! Resolution order:
//!   1. `TVMV_WEB_DIR` — explicit override, for testing an alternate web layer
//!   2. `<exe dir>/../share/tvmv/web` — installed layout
//!   3. `/usr/share/tvmv/web`, `/usr/local/share/tvmv/web`
//!   4. dev fallbacks relative to the crate: `../web`, then the pre-Task-1
//!      location `../Sources/TVMVCore/Resources/web`

use std::path::PathBuf;

pub fn web_dir() -> Option<PathBuf> {
    candidates().into_iter().find(|c| c.join("boot.js").is_file())
}

fn candidates() -> Vec<PathBuf> {
    let mut out = Vec::new();

    if let Some(dir) = std::env::var_os("TVMV_WEB_DIR") {
        out.push(PathBuf::from(dir));
    }

    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
    {
        out.push(dir.join("../share/tvmv/web"));
    }

    out.push(PathBuf::from("/usr/share/tvmv/web"));
    out.push(PathBuf::from("/usr/local/share/tvmv/web"));

    let crate_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    out.push(crate_root.join("../web"));
    out.push(crate_root.join("../Sources/TVMVCore/Resources/web"));

    out
}
