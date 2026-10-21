//! The native single-surface reader/editor: Markdown rendered in place with
//! its markup hidden, in one GtkTextView. See
//! `docs/superpowers/specs/2026-10-21-linux-native-editor-design.md`.

pub mod check;
pub mod document_view;
pub mod styler;
pub mod theme;
pub mod undo;
pub mod view;
pub mod window;
