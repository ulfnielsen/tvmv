//! Guards the one thing that silently breaks cross-platform rendering: the Mac
//! and Linux shells drifting onto different cmark-gfm revisions.
//!
//! The Mac resolves cmark-gfm through SwiftPM (`Package.resolved`); Linux
//! compiles the `linux/vendor/swift-cmark` submodule. Two mechanisms, one
//! revision — asserted here rather than hoped for.

use std::path::PathBuf;
use std::process::Command;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

/// The `swift-cmark` revision pinned in `Package.resolved`.
fn resolved_revision() -> String {
    let path = repo_root().join("Package.resolved");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));

    let pin = text
        .split("\"identity\"")
        .find(|chunk| chunk.contains("swift-cmark"))
        .expect("Package.resolved has a swift-cmark pin");

    let marker = "\"revision\"";
    let after = pin
        .find(marker)
        .map(|i| &pin[i + marker.len()..])
        .expect("swift-cmark pin has a revision");

    after
        .split('"')
        .nth(1)
        .expect("revision is a quoted string")
        .to_string()
}

/// The revision the vendored submodule is actually checked out at — i.e. the
/// source `build.rs` just compiled.
fn submodule_revision() -> String {
    let dir = repo_root().join("linux/vendor/swift-cmark");
    let out = Command::new("git")
        .args(["-C", &dir.to_string_lossy(), "rev-parse", "HEAD"])
        .output()
        .expect("git rev-parse runs");
    assert!(
        out.status.success(),
        "git rev-parse failed in {} — run: git submodule update --init --recursive",
        dir.display()
    );
    String::from_utf8(out.stdout).expect("utf-8 sha").trim().to_string()
}

#[test]
fn vendored_cmark_matches_the_mac_pin() {
    let resolved = resolved_revision();
    let vendored = submodule_revision();
    assert_eq!(
        vendored, resolved,
        "\ncmark-gfm revision drift:\n  \
         Package.resolved (Mac): {resolved}\n  \
         linux/vendor/swift-cmark: {vendored}\n\n\
         The two shells must compile the same parser or their HTML — and the\n\
         data-sourcepos anchors the editor sync depends on — can diverge.\n\
         Re-pin the submodule, or update both together and regenerate the goldens."
    );
}
