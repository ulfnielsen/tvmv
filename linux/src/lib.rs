//! TVMV for Linux — shared library half of the GTK4 shell.
//!
//! The web layer under `/web` (theme, outline extraction, find, editor,
//! source-position sync) is shared verbatim with the Mac and iOS apps. This
//! crate is only the shell around it. See
//! `docs/superpowers/specs/2026-08-26-tvmv-linux-design.md`.

pub mod app;
pub mod appearance;
pub mod assets;
pub mod offsets;
pub mod outline;
pub mod patch;
pub mod capi;
pub mod card;
pub mod chrome;
pub mod cmark;
pub mod document;
pub mod edit_rules;
pub mod editor;
pub mod find;
pub mod js;
pub mod layout;
pub mod preview;
pub mod reading;
pub mod print;
pub mod render;
pub mod review;
pub mod review_spans;
pub mod startup;
pub mod resources;
pub mod settings;
pub mod settings_ui;
pub mod theme;
pub mod watcher;
pub mod window;
