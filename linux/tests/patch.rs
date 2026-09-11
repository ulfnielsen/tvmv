//! Ported case-for-case from `Tests/TVMVCoreTests/TextPatcherTests.swift`, plus
//! cases specific to Rust's stricter string representation.

use tvmv::patch::{Patch, apply};

fn p(from: i64, to: i64, insert: &str) -> Patch {
    Patch::new(from, to, insert)
}

#[test]
fn insert() {
    assert_eq!(apply(&[p(5, 5, " brave")], "hello world", None).as_deref(), Some("hello brave world"));
}

#[test]
fn delete() {
    assert_eq!(apply(&[p(5, 11, "")], "hello world", None).as_deref(), Some("hello"));
}

#[test]
fn replace() {
    assert_eq!(apply(&[p(6, 11, "there")], "hello world", None).as_deref(), Some("hello there"));
}

#[test]
fn multiple_patches_apply_in_base_coordinates() {
    // Both ranges refer to the ORIGINAL text; a naive forward application
    // without offset care would corrupt the second.
    assert_eq!(
        apply(&[p(0, 1, "J"), p(6, 11, "moon")], "hello world", None).as_deref(),
        Some("Jello moon")
    );
}

#[test]
fn empty_patch_list_is_identity() {
    assert_eq!(apply(&[], "abc", None).as_deref(), Some("abc"));
}

#[test]
fn utf16_offsets_with_surrogate_pairs() {
    // "👍" is two UTF-16 units; CodeMirror counts in UTF-16.
    let base = "a👍b"; // offsets: a=0, 👍=1..3, b=3
    assert_eq!(apply(&[p(3, 4, "c")], base, None).as_deref(), Some("a👍c"));
    assert_eq!(apply(&[p(1, 3, "x")], base, None).as_deref(), Some("axb"));
}

#[test]
fn out_of_bounds_returns_none() {
    assert_eq!(apply(&[p(0, 99, "")], "short", None), None);
    assert_eq!(apply(&[p(-1, 2, "")], "short", None), None);
}

#[test]
fn overlapping_patches_return_none() {
    assert_eq!(apply(&[p(0, 5, "x"), p(3, 8, "y")], "0123456789", None), None);
}

#[test]
fn unordered_patches_return_none() {
    assert_eq!(apply(&[p(6, 8, "x"), p(0, 2, "y")], "0123456789", None), None);
}

#[test]
fn inverted_range_returns_none() {
    assert_eq!(apply(&[p(5, 2, "x")], "0123456789", None), None);
}

#[test]
fn expected_length_mismatch_returns_none() {
    assert_eq!(apply(&[p(0, 0, "xy")], "abc", Some(4)), None);
    assert_eq!(apply(&[p(0, 0, "xy")], "abc", Some(5)).as_deref(), Some("xyabc"));
}

// --- beyond the Swift suite ------------------------------------------------

/// The offsets are UTF-16, not bytes. "é" is 2 bytes but 1 UTF-16 unit, so a
/// byte-indexed implementation would slice mid-character here.
#[test]
fn multibyte_offsets_are_not_byte_offsets() {
    // "héllo": UTF-16 offsets h=0, é=1, l=2, l=3, o=4 — 5 units, 6 bytes.
    assert_eq!(apply(&[p(4, 5, "O")], "héllo", None).as_deref(), Some("héllO"));
    assert_eq!(apply(&[p(1, 2, "e")], "héllo", None).as_deref(), Some("hello"));
}

/// Expected length is counted in UTF-16 units, matching what editor.js posts.
#[test]
fn expected_length_counts_utf16_units() {
    // "a👍b" is 4 UTF-16 units; replacing "b" with "👍" gives 5.
    assert_eq!(apply(&[p(3, 4, "👍")], "a👍b", Some(5)).as_deref(), Some("a👍👍"));
    assert_eq!(apply(&[p(3, 4, "👍")], "a👍b", Some(4)), None);
}

/// Splitting a surrogate pair cannot be represented as a Rust `String`; it
/// becomes an incoherent-input rejection so the caller resyncs.
#[test]
fn splitting_a_surrogate_pair_returns_none() {
    // Cut between the two halves of "👍" (offset 1..2), leaving a lone surrogate.
    assert_eq!(apply(&[p(1, 2, "")], "a👍b", None), None);
}

/// Adjacent (touching but not overlapping) patches are legal: `from == previous to`.
#[test]
fn adjacent_patches_are_accepted() {
    assert_eq!(
        apply(&[p(0, 2, "AB"), p(2, 4, "CD")], "abcdef", None).as_deref(),
        Some("ABCDef")
    );
}

/// A patch at the very end of the document is in bounds.
#[test]
fn append_at_end_is_in_bounds() {
    assert_eq!(apply(&[p(3, 3, "!")], "abc", None).as_deref(), Some("abc!"));
}

#[test]
fn empty_document_accepts_an_insert() {
    assert_eq!(apply(&[p(0, 0, "hello")], "", None).as_deref(), Some("hello"));
    assert_eq!(apply(&[p(0, 1, "x")], "", None), None);
}
