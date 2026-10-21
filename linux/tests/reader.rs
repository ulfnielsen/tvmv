//! The native reader's pure parts. Slug cases are the Swift
//! `HeadingSluggerTests` (produced by boot.js's own slugger); link cases are
//! `NativeDocumentViewTests.testLinkTargets`.

use std::path::PathBuf;

use tvmv::layout::Heading;
use tvmv::reader::{HeadingSlugger, LinkTarget, find_matches, heading_for_anchor, link_target, outline};
use tvmv::reading::{Position, ReadingState};

#[test]
fn slugs_match_the_web_reader() {
    let mut slugger = HeadingSlugger::default();
    for (title, expected) in [
        ("Hello World", "hello-world"),
        ("Hello World", "hello-world-1"),
        ("Hello World-1", "hello-world-1-1"),
        ("Hello World", "hello-world-2"),
        ("Ünïcödé Straße", "ünïcödé-straße"),
        ("C++ & Rust!", "c-rust"),
        ("  spaced  out  ", "-spaced-out-"),
        ("emoji 😀 here", "emoji-here"),
        ("日本語 見出し", "日本語-見出し"),
        ("a_b-c", "a_b-c"),
        ("Ⅻ roman ½", "ⅻ-roman-½"),
    ] {
        assert_eq!(slugger.slug(title), expected, "{title}");
    }
}

fn heading(title: &str, at: usize) -> Heading {
    Heading { level: 2, title: title.into(), range: at..at + title.len() + 3 }
}

#[test]
fn outline_and_anchors_agree_on_duplicates() {
    let headings = [heading("Setup", 0), heading("Usage", 10), heading("Setup", 20)];
    let items = outline(&headings);
    let anchors: Vec<&str> = items.iter().map(|i| i.anchor.as_str()).collect();
    assert_eq!(anchors, ["setup", "usage", "setup-1"]);
    assert_eq!(heading_for_anchor(&headings, "setup-1").map(|h| h.range.start), Some(20));
    assert_eq!(heading_for_anchor(&headings, "setup").map(|h| h.range.start), Some(0));
    assert!(heading_for_anchor(&headings, "missing").is_none());
}

#[test]
fn links_leave_the_app_only_for_the_web_and_mail() {
    let root = std::env::temp_dir().join(format!("tvmv-links-{}", std::process::id()));
    let guide = root.join("guide");
    std::fs::create_dir_all(guide.join("folder.md")).unwrap();
    std::fs::write(guide.join("other.md"), "x").unwrap();
    std::fs::write(root.join("notes x.markdown"), "x").unwrap();
    std::fs::write(guide.join("run.sh"), "x").unwrap();
    let _ = std::os::unix::fs::symlink("/usr/bin/env", guide.join("trap.md"));
    let doc = guide.join("readme.md");
    let target = |link: &str| link_target(link, Some(&doc));
    let resolved = |p: PathBuf| p.canonicalize().unwrap();

    assert_eq!(target("#setup"), LinkTarget::Anchor("setup".into()));
    assert_eq!(target("#caf%C3%A9"), LinkTarget::Anchor("café".into()));
    assert_eq!(target("https://example.com/x"), LinkTarget::External("https://example.com/x".into()));
    assert_eq!(target("HTTP://example.com"), LinkTarget::External("HTTP://example.com".into()));
    assert_eq!(target("mailto:a@b.c"), LinkTarget::External("mailto:a@b.c".into()));
    assert_eq!(target("other.md"), LinkTarget::Document(resolved(guide.join("other.md"))));
    assert_eq!(target("../notes%20x.markdown#top"), LinkTarget::Document(resolved(root.join("notes x.markdown"))));

    assert_eq!(target("trap.md"), LinkTarget::Blocked, "a symlink to a program");
    assert_eq!(target("folder.md"), LinkTarget::Blocked, "a directory");
    assert_eq!(target("missing.md"), LinkTarget::Blocked);
    assert_eq!(target("run.sh"), LinkTarget::Blocked);
    assert_eq!(target("file:///usr/bin/env"), LinkTarget::Blocked);
    assert_eq!(target("javascript:alert(1)"), LinkTarget::Blocked);
    assert_eq!(target("ssh://host"), LinkTarget::Blocked);
    assert_eq!(target("/etc/hosts"), LinkTarget::Blocked);
    assert_eq!(link_target("other.md", None), LinkTarget::Blocked);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn find_ignores_case_and_does_not_overlap() {
    assert_eq!(find_matches("Abc abc ABC", "abc"), [0..3, 4..7, 8..11]);
    assert_eq!(find_matches("aaaa", "aa"), [0..2, 2..4]);
    assert_eq!(find_matches("**bold** text", "*b"), vec![1..3]);
    assert!(find_matches("abc", "").is_empty());
    assert!(find_matches("abc", "abcd").is_empty());
    // Non-ASCII queries, and offsets in bytes.
    assert_eq!(find_matches("Ünïcödé ünÏ", "ünï"), [0..5, 12..17]);
    assert_eq!(find_matches("café CAFÉ", "café"), [0..5, 6..11]);
    // An ASCII query never matches inside a multi-byte character.
    assert_eq!(find_matches("é e", "e"), vec![3..4]);
}

#[test]
fn reading_state_prefers_offsets_and_reads_legacy_fractions() {
    let legacy: ReadingState = serde_json::from_str(r#"{"position":0.4,"bookmark":0.7}"#).unwrap();
    assert_eq!(legacy.reading_position(), Some(Position::Fraction(0.4)));
    assert_eq!(legacy.bookmark_position(), Some(Position::Fraction(0.7)));

    let mut state = ReadingState { offset: Some(120), bookmark_offset: Some(900), ..legacy };
    assert_eq!(state.reading_position(), Some(Position::Offset(120)));
    assert_eq!(state.bookmark_position(), Some(Position::Offset(900)));
    state.clear_bookmark();
    assert_eq!(state.bookmark_position(), None);

    let fresh = ReadingState::default();
    assert_eq!(fresh.reading_position(), None);
    let json = serde_json::to_string(&fresh).unwrap();
    assert!(!json.contains("offset"), "{json}");
}
