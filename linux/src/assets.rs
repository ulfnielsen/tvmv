//! Resolution for the `tvmv-asset://` URI scheme.
//!
//! Port of `Sources/TVMVCore/AssetSchemeHandler.swift`. Host-based routing:
//!
//!   - `tvmv-asset://app/<path>` -> the bundled web resources (`app_base`)
//!   - `tvmv-asset://doc/<path>` -> the open document's directory (`doc_base`),
//!     confined against path traversal
//!
//! This module is the *resolution* half only — pure, synchronous, and testable
//! with no WebKit. The shell registers it with
//! `webkit_web_context_register_uri_scheme` and streams the resulting file
//! through a `GInputStream` (Task 8), which is why there is no chunking logic
//! here: the Swift side hand-rolls 1 MiB reads because `WKURLSchemeTask` wants
//! `didReceive(Data)` callbacks, whereas WebKitGTK takes a stream directly.

use std::path::{Component, Path, PathBuf};

use percent_encoding::percent_decode_str;

pub const SCHEME: &str = "tvmv-asset";

#[derive(Debug, PartialEq, Eq)]
pub enum AssetError {
    MalformedUrl,
    UnknownHost(String),
    NoDocumentDirectory,
    PathTraversal,
    NotFound,
}

impl std::fmt::Display for AssetError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MalformedUrl => write!(f, "malformed asset URL"),
            Self::UnknownHost(h) => write!(f, "unknown asset host: {h}"),
            Self::NoDocumentDirectory => write!(f, "no document directory"),
            Self::PathTraversal => write!(f, "path traversal rejected"),
            Self::NotFound => write!(f, "not found"),
        }
    }
}

impl std::error::Error for AssetError {}

pub struct AssetRouter {
    app_base: PathBuf,
    doc_base: Option<PathBuf>,
}

impl AssetRouter {
    pub fn new(app_base: impl Into<PathBuf>) -> Self {
        Self { app_base: normalize_lexically(&app_base.into()), doc_base: None }
    }

    /// Updated as the user opens different documents. `None` means "no document
    /// loaded yet", and any `doc` request fails until one is set.
    pub fn set_document_directory(&mut self, dir: Option<PathBuf>) {
        self.doc_base = dir.map(|d| normalize_lexically(&d));
    }

    pub fn resolve(&self, uri: &str) -> Result<PathBuf, AssetError> {
        let (host, encoded_path) = split_uri(uri)?;

        let base = match host.as_str() {
            "app" => &self.app_base,
            "doc" => self.doc_base.as_ref().ok_or(AssetError::NoDocumentDirectory)?,
            other => return Err(AssetError::UnknownHost(other.to_string())),
        };

        // Percent-decode *after* splitting: a linked image named "my file.png"
        // arrives as "my%20file.png", and "%2E%2E" must become ".." here so the
        // confinement check below is what rejects it.
        let decoded = percent_decode_str(encoded_path)
            .decode_utf8()
            .map_err(|_| AssetError::MalformedUrl)?;

        // An absolute path would make `join` discard the base entirely rather
        // than append to it.
        if Path::new(decoded.as_ref()).is_absolute() {
            return Err(AssetError::PathTraversal);
        }

        let candidate = normalize_lexically(&base.join(decoded.as_ref()));
        confine(&candidate, base)?;

        if !candidate.exists() {
            return Err(AssetError::NotFound);
        }
        Ok(candidate)
    }
}

/// Split `tvmv-asset://<host>/<path>` into its host and still-encoded path.
///
/// Hand-parsed rather than handed to a general URL crate on purpose. Those
/// normalise dot segments during parsing — including percent-encoded ones —
/// so `..` would be resolved away before this module ever saw it. That is safe
/// by accident, but it makes `confine` unreachable and therefore untested, and
/// it puts the traversal boundary inside a dependency's parsing rules instead
/// of in code with tests on it. Swift reads `percentEncodedPath`, which
/// likewise preserves the segments; this keeps the two in step.
fn split_uri(uri: &str) -> Result<(String, &str), AssetError> {
    // Strip any query or fragment first; neither is meaningful for a file.
    let uri = uri.split(['?', '#']).next().unwrap_or(uri);

    let prefix = format!("{SCHEME}://");
    // Scheme comparison is case-insensitive per RFC 3986.
    if uri.len() < prefix.len() || !uri[..prefix.len()].eq_ignore_ascii_case(&prefix) {
        return Err(AssetError::MalformedUrl);
    }
    let rest = &uri[prefix.len()..];

    let (host, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i + 1..]),
        None => (rest, ""),
    };
    if host.is_empty() {
        return Err(AssetError::MalformedUrl);
    }
    Ok((host.to_ascii_lowercase(), path))
}

/// Verify `candidate` is contained within `base`.
fn confine(candidate: &Path, base: &Path) -> Result<(), AssetError> {
    if candidate == base {
        return Ok(());
    }
    if candidate.starts_with(base) {
        return Ok(());
    }
    Err(AssetError::PathTraversal)
}

/// Resolve `.` and `..` **lexically**, without touching the filesystem.
///
/// This deliberately mirrors Swift's `standardizedFileURL`, which is also
/// lexical: a symlink *inside* the base that points outside it is not blocked
/// on either platform. Canonicalising here instead would be stricter than the
/// Mac and would make the same document render differently on the two — the one
/// outcome the shared-web-layer design exists to prevent. Escaping this way
/// requires the ability to plant a symlink next to the document, i.e. write
/// access to that directory already.
///
/// Worth revisiting as a hardening pass, but on **both** platforms together.
fn normalize_lexically(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                // Popping past the root is a no-op, matching `standardizedFileURL`.
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// MIME type from the path extension.
///
/// An explicit table rather than a database lookup: the served set is known —
/// the vendored web layer plus whatever a document links — and the three types
/// that *must* be right are `text/css`, `text/javascript`, and `font/woff2`.
/// WebKit ignores a stylesheet or refuses a script served as
/// `application/octet-stream`, and that failure is silent.
pub fn mime_type(path: &Path) -> &'static str {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default();

    match ext.as_str() {
        "css" => "text/css",
        "js" | "mjs" => "text/javascript",
        "html" | "htm" => "text/html",
        "json" | "map" => "application/json",
        "woff2" => "font/woff2",
        "woff" => "font/woff",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "svg" => "image/svg+xml",
        "webp" => "image/webp",
        "avif" => "image/avif",
        "bmp" => "image/bmp",
        "ico" => "image/vnd.microsoft.icon",
        "md" | "markdown" => "text/markdown",
        "txt" => "text/plain",
        "pdf" => "application/pdf",
        _ => "application/octet-stream",
    }
}
