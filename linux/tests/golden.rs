//! Golden HTML tests — the cross-platform rendering gate.
//!
//! The same corpus and the same expectations are asserted by the Swift suite
//! (`Tests/TVMVCoreTests/GoldenRenderTests.swift`). If the two platforms ever
//! stop agreeing, one of these two suites goes red rather than a user
//! discovering it as a sync bug.

use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../Fixtures")
}

/// Every `<name>.md` that has a committed expectation, plus the showcase
/// document, which lives one directory up.
fn cases() -> Vec<(String, PathBuf)> {
    let golden = fixtures().join("golden");
    let mut cases: Vec<(String, PathBuf)> = std::fs::read_dir(&golden)
        .expect("Fixtures/golden is readable")
        .map(|e| e.expect("dir entry").path())
        .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("md"))
        // README.md documents the corpus; it is not part of it.
        .filter(|p| p.file_stem().is_some_and(|s| s != "README"))
        .map(|p| (p.file_stem().unwrap().to_string_lossy().into_owned(), p))
        .collect();
    cases.push(("showcase".into(), fixtures().join("showcase.md")));
    cases.sort();
    assert!(cases.len() > 1, "fixture corpus is missing");
    cases
}

fn assert_matches(name: &str, input: &Path, source_pos: bool) {
    let suffix = if source_pos { "sourcepos.html" } else { "html" };
    let expected_path = fixtures().join("golden").join(format!("{name}.{suffix}"));

    let markdown = std::fs::read_to_string(input)
        .unwrap_or_else(|e| panic!("reading {}: {e}", input.display()));
    let expected = std::fs::read_to_string(&expected_path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", expected_path.display()));

    let actual = tvmv::render::render_html(&markdown, source_pos);

    if actual != expected {
        // Point at the first differing line; a whole-document diff of a 2KB
        // expectation is unreadable in test output.
        let (line, exp, act) = first_difference(&expected, &actual);
        panic!(
            "golden mismatch for {name} (source_pos={source_pos})\n\
             first difference at line {line}:\n\
             expected: {exp}\n\
             actual:   {act}\n\n\
             If cmark-gfm was intentionally re-pinned, regenerate with:\n  \
             cargo run --manifest-path linux/Cargo.toml --release -- <fixture> [--source-pos]\n\
             and re-run the Swift suite on the Mac before landing."
        );
    }
}

fn first_difference(expected: &str, actual: &str) -> (usize, String, String) {
    for (i, (e, a)) in expected.lines().zip(actual.lines()).enumerate() {
        if e != a {
            return (i + 1, e.to_string(), a.to_string());
        }
    }
    let n = expected.lines().count().min(actual.lines().count());
    (
        n + 1,
        expected.lines().nth(n).unwrap_or("<end of file>").to_string(),
        actual.lines().nth(n).unwrap_or("<end of file>").to_string(),
    )
}

#[test]
fn golden_html_matches() {
    for (name, path) in cases() {
        assert_matches(&name, &path, false);
    }
}

#[test]
fn golden_sourcepos_html_matches() {
    for (name, path) in cases() {
        assert_matches(&name, &path, true);
    }
}

/// `data-sourcepos` is the anchor the editor/preview sync maps through, so its
/// presence is asserted independently of the byte comparison above — a golden
/// file regenerated from a build with the option wired up wrong would otherwise
/// pass silently.
#[test]
fn sourcepos_option_actually_applies() {
    let markdown = "# Heading\n\npara\n";
    assert!(!tvmv::render::render_html(markdown, false).contains("data-sourcepos"));
    assert!(tvmv::render::render_html(markdown, true).contains("data-sourcepos"));
}

/// Matches the Swift renderer's contract: the four GFM core extensions are
/// attached, so their nodes emit extension HTML rather than plain text.
#[test]
fn gfm_extensions_are_attached() {
    let html = tvmv::render::render_html(
        "| a |\n| --- |\n| b |\n\n~~s~~\n\nwww.example.com\n\n- [x] done\n",
        false,
    );
    assert!(html.contains("<table>"), "table extension: {html}");
    assert!(html.contains("<del>"), "strikethrough extension: {html}");
    assert!(html.contains("<a href=\"http://www.example.com\""), "autolink: {html}");
    assert!(html.contains("type=\"checkbox\""), "tasklist extension: {html}");
}

/// The safe default must survive: raw HTML stripped, dangerous URL schemes
/// neutralised. The Swift side relies on this instead of sanitising in JS.
#[test]
fn unsafe_content_is_stripped_by_default() {
    let html = tvmv::render::render_html(
        "<script>alert(1)</script>\n\n[x](javascript:alert(1))\n",
        false,
    );
    assert!(!html.contains("<script>"), "raw HTML leaked: {html}");
    assert!(!html.contains("javascript:"), "javascript: URL leaked: {html}");
}

/// Embedded NULs truncate the document under `withCString`-style APIs. The Rust
/// side passes an explicit length, so it must not lose content.
#[test]
fn embedded_nul_does_not_truncate() {
    let html = tvmv::render::render_html("before\0after\n", false);
    assert!(html.contains("after"), "content lost after NUL: {html}");
}

#[test]
fn empty_input_renders_empty() {
    assert_eq!(tvmv::render::render_html("", false), "");
}
