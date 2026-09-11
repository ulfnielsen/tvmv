//! Applies editor patches to a document string.
//!
//! Port of `Sources/TVMVCore/TextPatcher.swift`. The editor page bridges
//! CodeMirror changes as `[from, to, insert]` triples coordinatized against the
//! document as of the last flush (a composed ChangeSet's original-side ranges:
//! ascending and non-overlapping). Applying them beats shipping the whole
//! document across the bridge on every settled keystroke batch.
//!
//! # Offsets are UTF-16 code units
//!
//! CodeMirror counts in UTF-16, `editor.js` posts `view.state.doc.length` in
//! UTF-16, and the Swift side applies them to an `NSMutableString`. Rust
//! `String` is UTF-8 and byte-indexed, so this module converts to `Vec<u16>`,
//! works there, and converts back. Indexing a Rust string by these offsets
//! directly would corrupt every document containing a non-ASCII character.
//!
//! Apply is strict: any incoherent input (out-of-bounds, overlapping,
//! unordered, or a result whose length disagrees with the editor's report)
//! returns `None` so the caller falls back to a full-text resync rather than
//! silently corrupting the document.

/// A single replacement, in pre-patch UTF-16 coordinates.
///
/// `from`/`to` are signed because they arrive from JS, where a negative value
/// is possible in principle; validation rejects them rather than trusting the
/// wire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Patch {
    pub from: i64,
    pub to: i64,
    pub insert: String,
}

impl Patch {
    pub fn new(from: i64, to: i64, insert: impl Into<String>) -> Self {
        Self { from, to, insert: insert.into() }
    }
}

/// Apply `patches` (ascending, non-overlapping) to `text`.
///
/// `expected_utf16_length` is the editor's post-change document length; a
/// mismatch means the two sides diverged and the result is discarded.
pub fn apply(patches: &[Patch], text: &str, expected_utf16_length: Option<usize>) -> Option<String> {
    let units: Vec<u16> = text.encode_utf16().collect();

    // Validate coherence against the ORIGINAL text before building anything.
    // `previous_end` starts at 0, so this also rejects a negative `from`.
    let mut previous_end: i64 = 0;
    for patch in patches {
        if patch.from < previous_end || patch.to < patch.from || patch.to > units.len() as i64 {
            return None;
        }
        previous_end = patch.to;
    }

    // Forward assembly in base coordinates. The Swift port splices in reverse
    // to keep earlier offsets valid while later text shifts; building a fresh
    // buffer reaches the same result in one pass without mutation.
    let mut out: Vec<u16> = Vec::with_capacity(units.len());
    let mut cursor: usize = 0;
    for patch in patches {
        out.extend_from_slice(&units[cursor..patch.from as usize]);
        out.extend(patch.insert.encode_utf16());
        cursor = patch.to as usize;
    }
    out.extend_from_slice(&units[cursor..]);

    if let Some(expected) = expected_utf16_length
        && out.len() != expected
    {
        return None;
    }

    // A patch boundary that split a surrogate pair leaves an unpaired unit.
    // Swift's NSMutableString tolerates that; Rust cannot represent it, so it
    // becomes another incoherent-input rejection — the same fallback path.
    String::from_utf16(&out).ok()
}
