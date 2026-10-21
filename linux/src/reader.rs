//! The native reader's pure parts: heading slugs, what a link may do, and
//! the outline. Ports of `HeadingSlugger.swift` and
//! `NativeDocumentController.linkTarget` / `outline(from:)`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use unicode_properties::{GeneralCategoryGroup, UnicodeGeneralCategory};

use crate::layout::Heading;
use crate::preview::OutlineItem;

/// boot.js's GitHub heading-slug algorithm, so `#anchor` links and the
/// outline resolve exactly as in the web reader: lowercase; keep letters,
/// numbers, marks, "_" and "-"; spaces become hyphens; runs of hyphens
/// collapse; duplicates get "-1", "-2", … (and a deduped slug is itself taken).
#[derive(Default)]
pub struct HeadingSlugger {
    seen: HashMap<String, usize>,
}

impl HeadingSlugger {
    pub fn base(text: &str) -> String {
        let mut out = String::new();
        for c in text.to_lowercase().chars() {
            match c.general_category_group() {
                // \p{L}, \p{N}, \p{M}: exactly the classes boot.js keeps.
                GeneralCategoryGroup::Letter | GeneralCategoryGroup::Number | GeneralCategoryGroup::Mark => out.push(c),
                _ if c == '_' || c == '-' => out.push(c),
                _ if c == ' ' => out.push('-'),
                _ => {}
            }
        }
        while out.contains("--") {
            out = out.replace("--", "-");
        }
        out
    }

    pub fn slug(&mut self, text: &str) -> String {
        let s = Self::base(text);
        let Some(&count) = self.seen.get(&s) else {
            self.seen.insert(s.clone(), 0);
            return s;
        };
        let mut n = count + 1;
        let mut candidate = format!("{s}-{n}");
        while self.seen.contains_key(&candidate) {
            n += 1;
            candidate = format!("{s}-{n}");
        }
        self.seen.insert(s, n);
        self.seen.insert(candidate.clone(), 0);
        candidate
    }
}

/// Outline entries for a layout's headings, with the web reader's slugs.
pub fn outline(headings: &[Heading]) -> Vec<OutlineItem> {
    let mut slugger = HeadingSlugger::default();
    headings
        .iter()
        .map(|h| OutlineItem { level: h.level as i64, title: h.title.clone(), anchor: slugger.slug(&h.title) })
        .collect()
}

/// The heading whose slug is `anchor`.
pub fn heading_for_anchor<'a>(headings: &'a [Heading], anchor: &str) -> Option<&'a Heading> {
    let mut slugger = HeadingSlugger::default();
    headings.iter().find(|h| slugger.slug(&h.title) == anchor)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkTarget {
    /// `#slug`: a heading in this document.
    Anchor(String),
    /// http, https or mailto: handed to the browser or mail app.
    External(String),
    /// A relative link to another Markdown file next to this one.
    Document(PathBuf),
    /// Anything else: other schemes, apps, scripts, absolute paths.
    Blocked,
}

pub const MARKDOWN_EXTENSIONS: [&str; 5] = ["md", "markdown", "mdown", "mkd", "mkdn"];

fn decode(s: &str) -> String {
    percent_encoding::percent_decode_str(s).decode_utf8().map_or_else(|_| s.to_string(), |d| d.into_owned())
}

/// The URL scheme, when `link` starts with one (RFC 3986: a letter, then
/// letters, digits, "+", "-" or ".", then ":").
fn scheme(link: &str) -> Option<&str> {
    let (scheme, _) = link.split_once(':')?;
    let mut chars = scheme.chars();
    let first = chars.next()?;
    (first.is_ascii_alphabetic() && chars.all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))).then_some(scheme)
}

/// What clicking `link` in the document at `document` may do. A document is
/// untrusted input: as in the web reader, only web and mail links leave the
/// app, and relative links open only existing regular Markdown files
/// (symlinks resolved first), never apps, folders, scripts or other schemes.
pub fn link_target(link: &str, document: Option<&Path>) -> LinkTarget {
    if let Some(anchor) = link.strip_prefix('#') {
        return LinkTarget::Anchor(decode(anchor));
    }
    if let Some(scheme) = scheme(link) {
        return if ["http", "https", "mailto"].contains(&scheme.to_ascii_lowercase().as_str()) {
            LinkTarget::External(link.to_string())
        } else {
            LinkTarget::Blocked
        };
    }
    let Some(folder) = document.and_then(Path::parent) else { return LinkTarget::Blocked };
    if link.starts_with('/') {
        return LinkTarget::Blocked;
    }
    let path = link.split('#').next().unwrap_or("");
    // Judge what is really there: a "notes.md" can be a symlink to a program
    // or a folder.
    let Ok(target) = folder.join(decode(path)).canonicalize() else { return LinkTarget::Blocked };
    let is_file = std::fs::metadata(&target).is_ok_and(|m| m.is_file());
    let markdown = target
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| MARKDOWN_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()));
    if is_file && markdown { LinkTarget::Document(target) } else { LinkTarget::Blocked }
}

/// Where `query` occurs in `text`, ignoring case, without overlaps. Find
/// searches the source, markup included, as on macOS.
pub fn find_matches(text: &str, query: &str) -> Vec<std::ops::Range<usize>> {
    let mut out = Vec::new();
    if query.is_empty() {
        return out;
    }
    if query.is_ascii() {
        // ASCII never matches inside a multi-byte character: those bytes are
        // all above 0x7F.
        let (hay, needle) = (text.as_bytes(), query.as_bytes());
        let mut i = 0;
        while i + needle.len() <= hay.len() {
            if hay[i..i + needle.len()].eq_ignore_ascii_case(needle) {
                out.push(i..i + needle.len());
                i += needle.len();
            } else {
                i += 1;
            }
        }
        return out;
    }
    let needle: Vec<char> = query.chars().flat_map(char::to_lowercase).collect();
    let mut from = 0;
    'outer: while from < text.len() {
        let mut chars = text[from..].char_indices().flat_map(|(i, c)| c.to_lowercase().map(move |l| (i, c, l)));
        let mut end = from;
        for &n in &needle {
            match chars.next() {
                Some((i, c, l)) if l == n => end = from + i + c.len_utf8(),
                _ => {
                    from += text[from..].chars().next().map_or(1, char::len_utf8);
                    continue 'outer;
                }
            }
        }
        out.push(from..end);
        from = end;
    }
    out
}
