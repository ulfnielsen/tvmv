//! A read-only view of a cmark-gfm syntax tree, for `layout.rs`.
//!
//! Parses with the same pinned library, the same four extensions and source
//! positions on, as `MarkdownLayoutParser.swift` does. Footnotes stay off,
//! as on the Swift side: the layout reads a `[^rv-…]` ref as a link and a
//! thread as a paragraph, and the review fold replaces both.

use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::marker::PhantomData;

unsafe extern "C" {
    fn cmark_gfm_core_extensions_ensure_registered();
    fn cmark_parser_new(options: c_int) -> *mut c_void;
    fn cmark_parser_free(parser: *mut c_void);
    fn cmark_find_syntax_extension(name: *const c_char) -> *mut c_void;
    fn cmark_parser_attach_syntax_extension(parser: *mut c_void, ext: *mut c_void) -> c_int;
    fn cmark_parser_feed(parser: *mut c_void, buffer: *const c_char, len: usize);
    fn cmark_parser_finish(parser: *mut c_void) -> *mut c_void;
    fn cmark_node_free(node: *mut c_void);

    fn cmark_node_first_child(node: *mut c_void) -> *mut c_void;
    fn cmark_node_next(node: *mut c_void) -> *mut c_void;
    fn cmark_node_get_type_string(node: *mut c_void) -> *const c_char;
    fn cmark_node_get_literal(node: *mut c_void) -> *const c_char;
    fn cmark_node_get_start_line(node: *mut c_void) -> c_int;
    fn cmark_node_get_start_column(node: *mut c_void) -> c_int;
    fn cmark_node_get_end_line(node: *mut c_void) -> c_int;
    fn cmark_node_get_end_column(node: *mut c_void) -> c_int;
    fn cmark_node_get_list_type(node: *mut c_void) -> c_int;
    fn cmark_node_get_heading_level(node: *mut c_void) -> c_int;
    fn cmark_node_get_fenced(node: *mut c_void, length: *mut c_int, offset: *mut c_int, character: *mut c_char) -> c_int;
    fn cmark_node_get_fence_info(node: *mut c_void) -> *const c_char;
    fn cmark_node_get_url(node: *mut c_void) -> *const c_char;
    fn cmark_gfm_extensions_get_tasklist_item_checked(node: *mut c_void) -> bool;
}

const CMARK_OPT_SOURCEPOS: c_int = 1 << 1;
const CMARK_ORDERED_LIST: c_int = 2;
const EXTENSIONS: [&str; 4] = ["table", "strikethrough", "autolink", "tasklist"];

pub struct Document {
    parser: *mut c_void,
    root: *mut c_void,
}

impl Document {
    pub fn parse(text: &str) -> Option<Document> {
        unsafe { cmark_gfm_core_extensions_ensure_registered() };
        let parser = unsafe { cmark_parser_new(CMARK_OPT_SOURCEPOS) };
        if parser.is_null() {
            return None;
        }
        for name in EXTENSIONS {
            let name = CString::new(name).expect("extension name has no interior nul");
            let ext = unsafe { cmark_find_syntax_extension(name.as_ptr()) };
            if !ext.is_null() {
                unsafe { cmark_parser_attach_syntax_extension(parser, ext) };
            }
        }
        unsafe { cmark_parser_feed(parser, text.as_ptr() as *const c_char, text.len()) };
        let root = unsafe { cmark_parser_finish(parser) };
        if root.is_null() {
            unsafe { cmark_parser_free(parser) };
            return None;
        }
        Some(Document { parser, root })
    }

    pub fn root(&self) -> Node<'_> {
        Node(self.root, PhantomData)
    }
}

impl Drop for Document {
    fn drop(&mut self) {
        unsafe {
            cmark_node_free(self.root);
            cmark_parser_free(self.parser);
        }
    }
}

/// A node, valid while its document is.
#[derive(Clone, Copy)]
pub struct Node<'a>(*mut c_void, PhantomData<&'a Document>);

fn string(ptr: *const c_char) -> String {
    if ptr.is_null() { String::new() } else { unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned() }
}

impl<'a> Node<'a> {
    pub fn kind(self) -> &'a str {
        let ptr = unsafe { cmark_node_get_type_string(self.0) };
        if ptr.is_null() { "" } else { unsafe { CStr::from_ptr(ptr) }.to_str().unwrap_or("") }
    }

    pub fn children(self) -> Vec<Node<'a>> {
        let mut out = Vec::new();
        let mut child = unsafe { cmark_node_first_child(self.0) };
        while !child.is_null() {
            out.push(Node(child, PhantomData));
            child = unsafe { cmark_node_next(child) };
        }
        out
    }

    pub fn first_child(self) -> Option<Node<'a>> {
        let child = unsafe { cmark_node_first_child(self.0) };
        (!child.is_null()).then_some(Node(child, PhantomData))
    }

    pub fn literal(self) -> String {
        string(unsafe { cmark_node_get_literal(self.0) })
    }

    /// cmark's 1-based start line and column, end line and column (columns
    /// in bytes, the end inclusive).
    pub fn position(self) -> (i64, i64, i64, i64) {
        unsafe {
            (
                cmark_node_get_start_line(self.0) as i64,
                cmark_node_get_start_column(self.0) as i64,
                cmark_node_get_end_line(self.0) as i64,
                cmark_node_get_end_column(self.0) as i64,
            )
        }
    }

    pub fn is_ordered_list(self) -> bool {
        unsafe { cmark_node_get_list_type(self.0) == CMARK_ORDERED_LIST }
    }

    pub fn heading_level(self) -> usize {
        unsafe { cmark_node_get_heading_level(self.0).max(0) as usize }
    }

    /// For a fenced code block: the fence's length and character.
    pub fn fence(self) -> Option<(usize, u8)> {
        let (mut length, mut offset, mut character): (c_int, c_int, c_char) = (0, 0, 0);
        let fenced = unsafe { cmark_node_get_fenced(self.0, &mut length, &mut offset, &mut character) };
        (fenced != 0).then_some((length.max(0) as usize, character as u8))
    }

    pub fn fence_info(self) -> String {
        string(unsafe { cmark_node_get_fence_info(self.0) })
    }

    pub fn url(self) -> String {
        string(unsafe { cmark_node_get_url(self.0) })
    }

    pub fn task_checked(self) -> bool {
        unsafe { cmark_gfm_extensions_get_tasklist_item_checked(self.0) }
    }
}
