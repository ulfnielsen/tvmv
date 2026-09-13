//! GitHub-Flavored Markdown -> HTML, mirroring `Sources/TVMVCore/MarkdownRenderer.swift`.
//!
//! Both shells call the same cmark-gfm C library at the same pinned revision
//! with the same options and the same four extensions, in the same order, so
//! their output is byte-identical. Any change here needs the matching change in
//! the Swift renderer, and `tests/golden.rs` is the gate.

use std::ffi::{CStr, CString, c_char, c_int, c_void};

unsafe extern "C" {
    fn cmark_gfm_core_extensions_ensure_registered();
    fn cmark_parser_new(options: c_int) -> *mut c_void;
    fn cmark_parser_free(parser: *mut c_void);
    fn cmark_find_syntax_extension(name: *const c_char) -> *mut c_void;
    fn cmark_parser_attach_syntax_extension(parser: *mut c_void, ext: *mut c_void) -> c_int;
    fn cmark_parser_feed(parser: *mut c_void, buffer: *const c_char, len: usize);
    fn cmark_parser_finish(parser: *mut c_void) -> *mut c_void;
    fn cmark_parser_get_syntax_extensions(parser: *mut c_void) -> *mut c_void;
    fn cmark_render_html(node: *mut c_void, options: c_int, exts: *mut c_void) -> *mut c_char;
    fn cmark_node_free(node: *mut c_void);
    fn free(ptr: *mut c_void);
}

/// Keeps the safe default: raw HTML and `javascript:`/`data:` links are stripped.
const CMARK_OPT_DEFAULT: c_int = 0;
/// Adds `data-sourcepos="line:col-line:col"` to block elements.
const CMARK_OPT_SOURCEPOS: c_int = 1 << 1;

/// The GFM core extensions, in the order the Swift renderer attaches them.
const EXTENSIONS: [&str; 4] = ["table", "strikethrough", "autolink", "tasklist"];

/// Parse GitHub-Flavored Markdown and render it to an HTML string.
///
/// When `source_pos` is true, block elements carry `data-sourcepos` attributes —
/// the anchor the editor/preview sync maps through. False keeps the output
/// byte-identical to what the QuickLook extension produces.
pub fn render_html(markdown: &str, source_pos: bool) -> String {
    // Registers the GFM core extensions exactly once per process, populating the
    // global registry `cmark_find_syntax_extension` queries. Idempotent.
    unsafe { cmark_gfm_core_extensions_ensure_registered() };

    let options = if source_pos { CMARK_OPT_SOURCEPOS } else { CMARK_OPT_DEFAULT };

    let parser = unsafe { cmark_parser_new(options) };
    if parser.is_null() {
        return String::new();
    }
    // From here every early return must free the parser.
    let _parser = ParserGuard(parser);

    for name in EXTENSIONS {
        let cname = CString::new(name).expect("extension name has no interior nul");
        let ext = unsafe { cmark_find_syntax_extension(cname.as_ptr()) };
        if !ext.is_null() {
            unsafe { cmark_parser_attach_syntax_extension(parser, ext) };
        }
    }

    // Feed the raw bytes. Unlike the Swift side's `withCString`, this passes the
    // length explicitly, so an embedded NUL truncates nothing.
    unsafe { cmark_parser_feed(parser, markdown.as_ptr() as *const c_char, markdown.len()) };

    let document = unsafe { cmark_parser_finish(parser) };
    if document.is_null() {
        return String::new();
    }
    let _document = NodeGuard(document);

    // The HTML renderer needs the active extension list so extension nodes
    // (tasklist checkboxes, tables) emit their custom HTML.
    let exts = unsafe { cmark_parser_get_syntax_extensions(parser) };

    let html = unsafe { cmark_render_html(document, options, exts) };
    if html.is_null() {
        return String::new();
    }

    let out = unsafe { CStr::from_ptr(html) }.to_string_lossy().into_owned();
    unsafe { free(html as *mut c_void) };
    out
}

struct ParserGuard(*mut c_void);
impl Drop for ParserGuard {
    fn drop(&mut self) {
        unsafe { cmark_parser_free(self.0) };
    }
}

struct NodeGuard(*mut c_void);
impl Drop for NodeGuard {
    fn drop(&mut self) {
        unsafe { cmark_node_free(self.0) };
    }
}
