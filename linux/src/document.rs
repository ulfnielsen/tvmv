//! The editable document: text, dirtiness, and saving.
//!
//! Port of the state `ViewerModel.swift` keeps around an open file. Deliberately
//! free of GTK and WebKit so the rules that can corrupt a file — patch
//! application, newline fidelity, atomic writes — are testable headless.
//!
//! `text` is always LF-normalised, because CodeMirror and `data-sourcepos` both
//! count in LF lines. The file's original newline style is remembered and
//! restored on save, so opening and saving a CRLF file does not silently
//! rewrite every line ending.

use std::path::{Path, PathBuf};

use crate::patch::{self, Patch};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Newline {
    Lf,
    Crlf,
}

impl Newline {
    /// CRLF only if the file uses it consistently enough to be intentional —
    /// a stray `\r\n` in an otherwise-LF file should not convert the whole
    /// document on save.
    fn detect(raw: &str) -> Self {
        let crlf = raw.matches("\r\n").count();
        if crlf == 0 {
            return Self::Lf;
        }
        let lf = raw.matches('\n').count();
        if crlf * 2 >= lf { Self::Crlf } else { Self::Lf }
    }
}

pub struct Document {
    path: PathBuf,
    /// Always LF-normalised.
    text: String,
    /// The text as of the last successful load or save.
    last_saved: String,
    newline: Newline,
}

impl Document {
    pub fn load(path: impl Into<PathBuf>) -> std::io::Result<Self> {
        let path = path.into();
        let raw = std::fs::read_to_string(&path)?;
        let newline = Newline::detect(&raw);
        let text = raw.replace("\r\n", "\n");
        Ok(Self { path, last_saved: text.clone(), text, newline })
    }

    /// A blank document standing in for a file that could not be read, so a
    /// window still opens (with an error on stderr) instead of vanishing.
    pub fn empty(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            text: String::new(),
            last_saved: String::new(),
            newline: Newline::Lf,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn is_dirty(&self) -> bool {
        self.text != self.last_saved
    }

    /// Adopt new text wholesale (a full resync from the editor).
    pub fn set_text(&mut self, text: String) {
        self.text = text;
    }

    /// Apply settled editor patches.
    ///
    /// Returns `false` when the payload is incoherent — bad ranges, length
    /// mismatch, empty patch list from a failed parse — meaning the caller must
    /// pull the full document instead. The editor stays authoritative; the
    /// model never guesses.
    #[must_use]
    pub fn apply_patches(&mut self, patches: &[Patch], expected_utf16_length: usize) -> bool {
        if patches.is_empty() {
            return false;
        }
        match patch::apply(patches, &self.text, Some(expected_utf16_length)) {
            Some(updated) => {
                self.text = updated;
                true
            }
            None => false,
        }
    }

    /// Write atomically: a crash mid-write must not truncate the user's file.
    ///
    /// The temp file is created beside the target so the rename stays on one
    /// filesystem, and the original's permissions are carried over — writing
    /// through a temp file otherwise silently resets the mode.
    pub fn save(&mut self) -> std::io::Result<()> {
        let out = match self.newline {
            Newline::Lf => self.text.clone(),
            Newline::Crlf => self.text.replace('\n', "\r\n"),
        };

        let temp = self.path.with_extension("tvmv-save");
        std::fs::write(&temp, &out)?;

        #[cfg(unix)]
        if let Ok(meta) = std::fs::metadata(&self.path) {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(
                &temp,
                std::fs::Permissions::from_mode(meta.permissions().mode()),
            );
        }

        if let Err(e) = std::fs::rename(&temp, &self.path) {
            let _ = std::fs::remove_file(&temp);
            return Err(e);
        }
        self.last_saved = self.text.clone();
        Ok(())
    }

    /// The text as of the last load or save, LF-normalised.
    ///
    /// Used to recognise our *own* writes: the watcher cannot tell them from a
    /// third party's, so a change whose content already equals this is ignored.
    pub fn last_saved(&self) -> &str {
        &self.last_saved
    }

    /// Read the file fresh and LF-normalise it, without adopting it.
    pub fn read_from_disk(&self) -> std::io::Result<String> {
        Ok(std::fs::read_to_string(&self.path)?.replace("\r\n", "\n"))
    }

    /// Treat the current text as saved without writing it.
    ///
    /// Only for an explicit "discard" — it makes `is_dirty` false so the close
    /// guard stops asking. It does not touch the file.
    pub fn mark_clean(&mut self) {
        self.last_saved = self.text.clone();
    }

    /// Re-read from disk, discarding unsaved edits.
    pub fn reload(&mut self) -> std::io::Result<()> {
        let reloaded = Self::load(&self.path)?;
        self.text = reloaded.text;
        self.last_saved = reloaded.last_saved;
        self.newline = reloaded.newline;
        Ok(())
    }

    /// Window title: the filename, marked when there are unsaved edits.
    pub fn title(&self) -> String {
        let name = self
            .path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "tvmv".to_string());
        if self.is_dirty() { format!("• {name}") } else { name }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str, contents: &str) -> PathBuf {
        let dir = std::env::temp_dir().join("tvmv-document-tests");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(name);
        std::fs::write(&path, contents).unwrap();
        path
    }

    #[test]
    fn loads_and_starts_clean() {
        let p = temp("clean.md", "# Title\n\nBody\n");
        let doc = Document::load(&p).unwrap();
        assert_eq!(doc.text(), "# Title\n\nBody\n");
        assert!(!doc.is_dirty());
        assert_eq!(doc.title(), "clean.md");
    }

    #[test]
    fn edits_mark_dirty_and_saving_clears_it() {
        let p = temp("dirty.md", "one\n");
        let mut doc = Document::load(&p).unwrap();

        doc.set_text("two\n".into());
        assert!(doc.is_dirty());
        assert_eq!(doc.title(), "• dirty.md");

        doc.save().unwrap();
        assert!(!doc.is_dirty());
        assert_eq!(doc.title(), "dirty.md");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "two\n");
    }

    /// Typing back to the original content is not dirty — dirtiness compares to
    /// the saved text, not "has been edited".
    #[test]
    fn returning_to_saved_text_is_clean() {
        let p = temp("undo.md", "one\n");
        let mut doc = Document::load(&p).unwrap();
        doc.set_text("changed\n".into());
        assert!(doc.is_dirty());
        doc.set_text("one\n".into());
        assert!(!doc.is_dirty());
    }

    #[test]
    fn patches_apply_and_incoherent_ones_are_rejected() {
        let p = temp("patch.md", "hello world\n");
        let mut doc = Document::load(&p).unwrap();

        // "hello world\n" is 12 UTF-16 units; replacing "world" with "there"
        // keeps the length.
        assert!(doc.apply_patches(&[Patch::new(6, 11, "there")], 12));
        assert_eq!(doc.text(), "hello there\n");

        // Out of bounds: rejected, and the text is untouched.
        assert!(!doc.apply_patches(&[Patch::new(0, 99, "x")], 5));
        assert_eq!(doc.text(), "hello there\n");

        // Length disagreement: rejected.
        assert!(!doc.apply_patches(&[Patch::new(0, 0, "x")], 99));
        assert_eq!(doc.text(), "hello there\n");

        // An empty list means the payload failed to parse -> resync.
        assert!(!doc.apply_patches(&[], 12));
    }

    /// A CRLF file must still be CRLF after a round-trip, or saving rewrites
    /// every line and produces a whole-file diff.
    #[test]
    fn crlf_survives_a_round_trip() {
        let p = temp("crlf.md", "one\r\ntwo\r\nthree\r\n");
        let mut doc = Document::load(&p).unwrap();

        // The model always sees LF.
        assert_eq!(doc.text(), "one\ntwo\nthree\n");

        doc.set_text("one\ntwo\nthree\nfour\n".into());
        doc.save().unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "one\r\ntwo\r\nthree\r\nfour\r\n");
    }

    #[test]
    fn lf_file_stays_lf() {
        let p = temp("lf.md", "one\ntwo\n");
        let mut doc = Document::load(&p).unwrap();
        doc.set_text("one\ntwo\nthree\n".into());
        doc.save().unwrap();
        assert!(!std::fs::read_to_string(&p).unwrap().contains('\r'));
    }

    /// One stray CRLF should not convert an otherwise-LF document.
    #[test]
    fn mostly_lf_file_is_treated_as_lf() {
        let p = temp("mixed.md", "a\nb\nc\r\nd\ne\nf\n");
        let mut doc = Document::load(&p).unwrap();
        doc.set_text(doc.text().to_string() + "g\n");
        doc.save().unwrap();
        assert!(!std::fs::read_to_string(&p).unwrap().contains('\r'));
    }

    #[test]
    fn save_leaves_no_temp_file() {
        let p = temp("atomic.md", "x\n");
        let mut doc = Document::load(&p).unwrap();
        doc.set_text("y\n".into());
        doc.save().unwrap();
        assert!(!p.with_extension("tvmv-save").exists());
    }

    #[cfg(unix)]
    #[test]
    fn save_preserves_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let p = temp("perms.md", "x\n");
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o640)).unwrap();

        let mut doc = Document::load(&p).unwrap();
        doc.set_text("y\n".into());
        doc.save().unwrap();

        let mode = std::fs::metadata(&p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o640, "writing through a temp file reset the mode");
    }

    /// The watcher fires on our own save exactly as it does on anyone else's.
    /// Content comparison is what tells them apart — a timing window would not,
    /// and getting it wrong means an endless save/reload loop.
    #[test]
    fn our_own_save_is_recognisable_on_disk() {
        let p = temp("selfsave.md", "before\n");
        let mut doc = Document::load(&p).unwrap();

        doc.set_text("after\n".into());
        doc.save().unwrap();

        // What the watcher would see equals what we just wrote: ignore it.
        assert_eq!(doc.read_from_disk().unwrap(), doc.last_saved());
    }

    #[test]
    fn a_third_party_write_is_distinguishable() {
        let p = temp("thirdparty.md", "before\n");
        let doc = Document::load(&p).unwrap();

        std::fs::write(&p, "someone else wrote this\n").unwrap();
        assert_ne!(doc.read_from_disk().unwrap(), doc.last_saved());
    }

    /// A CRLF file rewritten externally must still compare equal after our own
    /// save — the comparison happens on LF-normalised text, or every save of a
    /// CRLF file would look like a foreign change and prompt a reload.
    #[test]
    fn self_save_recognition_survives_crlf() {
        let p = temp("selfsave-crlf.md", "a\r\nb\r\n");
        let mut doc = Document::load(&p).unwrap();

        doc.set_text("a\nb\nc\n".into());
        doc.save().unwrap();

        assert!(std::fs::read_to_string(&p).unwrap().contains("\r\n"));
        assert_eq!(doc.read_from_disk().unwrap(), doc.last_saved());
    }

    #[test]
    fn reload_discards_unsaved_edits() {
        let p = temp("reload.md", "disk\n");
        let mut doc = Document::load(&p).unwrap();
        doc.set_text("edited\n".into());
        assert!(doc.is_dirty());

        std::fs::write(&p, "changed on disk\n").unwrap();
        doc.reload().unwrap();
        assert_eq!(doc.text(), "changed on disk\n");
        assert!(!doc.is_dirty());
    }
}
