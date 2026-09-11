//! Compiles the vendored cmark-gfm C sources.
//!
//! The submodule at `vendor/swift-cmark` is pinned to the SAME revision the Mac
//! app resolves through SwiftPM (see `Package.resolved`). Compiling that exact
//! source rather than linking a distro `libcmark-gfm` is what makes the two
//! platforms emit byte-identical HTML *by construction* instead of by luck —
//! `data-sourcepos` is the anchor the editor/preview sync maps through, so a
//! parser that is merely close is worse than one that is obviously wrong.
//!
//! `tests/vendor_pin.rs` asserts the submodule and `Package.resolved` agree.
//!
//! Upstream builds these sources with CMake, but swift-cmark checks in the
//! headers CMake would otherwise generate (`cmark-gfm_config.h`,
//! `cmark-gfm_version.h`, `export.h`) so SwiftPM can build them directly. That
//! means `cc` can too — no CMake, and no system cmark-gfm package.

use std::path::{Path, PathBuf};

/// Sources excluded from both directories: re2c inputs, not C.
const EXCLUDED: &[&str] = &["scanners.re", "ext_scanners.re"];

fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("vendor/swift-cmark");

    let sentinel = root.join("src/include/cmark-gfm.h");
    if !sentinel.exists() {
        panic!(
            "vendored cmark-gfm sources missing at {}\n\
             run: git submodule update --init --recursive",
            root.display()
        );
    }

    let mut build = cc::Build::new();
    build
        .include(root.join("src/include"))
        .include(root.join("extensions/include"))
        .warnings(false);

    for dir in ["src", "extensions"] {
        for file in c_sources(&root.join(dir)) {
            build.file(file);
        }
    }

    build.compile("cmark-gfm");

    println!("cargo:rerun-if-changed={}", root.join("src").display());
    println!("cargo:rerun-if-changed={}", root.join("extensions").display());
}

/// Every `.c` file in `dir`, sorted so the compile is reproducible, minus the
/// re2c inputs.
fn c_sources(dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("reading {}: {e}", dir.display()))
        .map(|entry| entry.expect("dir entry").path())
        .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("c"))
        .filter(|p| !EXCLUDED.iter().any(|name| p.ends_with(name)))
        .collect();
    files.sort();
    files
}
