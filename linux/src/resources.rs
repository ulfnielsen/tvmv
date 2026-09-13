//! Where the shared web layer comes from.
//!
//! Normally: the binary itself. `build.rs` compiles every file of the web layer
//! in, so the executable is self-contained — nothing to install beside it,
//! nothing to find at runtime, and no way for a stale copy under
//! `/usr/share/tvmv/web` to be served instead of the one this build was made
//! from. `ResourceLocator.swift` has the same job on the Mac and a bundle to do
//! it with; this is the equivalent guarantee without one.
//!
//! `TVMV_WEB_DIR` overrides it with a directory, for pointing the shell at a
//! different web layer without rebuilding. Editing the real one needs no
//! override: every file is a `rerun-if-changed` input, so `cargo run` rebuilds.
//!
//! The directory search below is kept for that override and for the tools that
//! still want a path on disk.

use std::path::PathBuf;

use crate::assets::WebSource;

/// The web layer for this process.
pub fn web_source() -> WebSource {
    match std::env::var_os("TVMV_WEB_DIR") {
        Some(dir) => override_source(PathBuf::from(dir)),
        None => WebSource::Embedded,
    }
}

/// Honour `TVMV_WEB_DIR` only if it actually holds a web layer.
///
/// Taking it on faith is worse than it sounds: every asset 404s, so the page
/// never loads, nothing is drawn, and `--snapshot` and `--pdf` wait forever for
/// a `renderComplete` that cannot come — a hang, with no output and no error.
/// That was the observed behaviour of a mistyped path. The built-in layer is
/// always there to fall back to, so a typo costs a warning instead.
fn override_source(dir: PathBuf) -> WebSource {
    if dir.join("boot.js").is_file() {
        return WebSource::Directory(dir);
    }
    eprintln!(
        "tvmv: TVMV_WEB_DIR={} has no boot.js — using the built-in web layer",
        dir.display()
    );
    WebSource::Embedded
}

/// A web layer on disk, if one can be found. Only the `TVMV_WEB_DIR` override
/// and the test helpers need this; the app itself carries its own.
pub fn web_dir() -> Option<PathBuf> {
    candidates().into_iter().find(|c| c.join("boot.js").is_file())
}

fn candidates() -> Vec<PathBuf> {
    let mut out = Vec::new();

    if let Some(dir) = std::env::var_os("TVMV_WEB_DIR") {
        out.push(PathBuf::from(dir));
    }

    // The repository copy. No installed paths are searched: nothing installs a
    // web layer any more, and listing `/usr/share/tvmv/web` would invite
    // serving a leftover from an older install instead of this build's own.
    let crate_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    out.push(crate_root.join("../web"));
    out.push(crate_root.join("../Sources/TVMVCore/Resources/web"));

    out
}

#[cfg(test)]
mod tests {
    use super::{WebSource, override_source};

    #[test]
    fn a_directory_with_a_web_layer_is_honoured() {
        let dir = std::env::temp_dir().join("tvmv-web-source-ok");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("boot.js"), "//").unwrap();
        assert_eq!(override_source(dir.clone()), WebSource::Directory(dir.clone()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The mistyped-path case. Falling back beats hanging `--snapshot` on a
    /// render that can never complete.
    #[test]
    fn a_directory_without_one_falls_back() {
        let dir = std::env::temp_dir().join("tvmv-web-source-missing");
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(override_source(dir.clone()), WebSource::Embedded);

        // Present but not a web layer: same answer.
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("readme.txt"), "not a web layer").unwrap();
        assert_eq!(override_source(dir.clone()), WebSource::Embedded);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
