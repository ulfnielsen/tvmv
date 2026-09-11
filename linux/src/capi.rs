//! C ABI for the thumbnail card.
//!
//! Exists so the KDE plugin (`linux/kio-thumbnail/`) draws with the *same* code
//! as the freedesktop thumbnailer, rather than reimplementing the card in C++.
//! One renderer means a `.md` looks identical in Files, Dolphin and Thunar.
//!
//! Everything is PNG bytes over the boundary: no structs, no ownership rules
//! beyond "free what you were given with `tvmv_card_free`".

use std::ffi::{c_char, c_int, c_uchar};

/// Render a markdown document to a PNG thumbnail.
///
/// - `markdown` / `markdown_len`: the document bytes. Not required to be valid
///   UTF-8; invalid sequences are replaced rather than rejected, because a file
///   manager runs this over whatever is on disk.
/// - `title`: NUL-terminated fallback title (usually the filename) used when the
///   document has no heading. May be null.
/// - `size`: edge length in pixels, clamped to 16..=1024.
/// - `dark`: non-zero for the dark theme.
/// - `out_len`: receives the PNG length.
///
/// Returns a pointer to `out_len` PNG bytes, or null on failure. Free it with
/// [`tvmv_card_free`].
///
/// # Safety
/// `markdown` must point to `markdown_len` readable bytes; `title`, if non-null,
/// must be a valid NUL-terminated string; `out_len` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tvmv_card_render_png(
    markdown: *const c_uchar,
    markdown_len: usize,
    title: *const c_char,
    size: c_int,
    dark: c_int,
    out_len: *mut usize,
) -> *mut c_uchar {
    if out_len.is_null() {
        return std::ptr::null_mut();
    }
    // Clear the length before any early return: a caller that checks the length
    // rather than the pointer would otherwise read a stale value on failure.
    unsafe { *out_len = 0 };
    if markdown.is_null() {
        return std::ptr::null_mut();
    }

    let bytes = unsafe { std::slice::from_raw_parts(markdown, markdown_len) };
    let text = String::from_utf8_lossy(bytes);

    let fallback = if title.is_null() {
        String::from("Untitled")
    } else {
        unsafe { std::ffi::CStr::from_ptr(title) }.to_string_lossy().into_owned()
    };

    let summary = crate::card::summarize(&text, &fallback, 8);
    let Ok(surface) = crate::card::draw(&summary, size.clamp(16, 1024), dark != 0) else {
        return std::ptr::null_mut();
    };

    let mut png: Vec<u8> = Vec::new();
    if surface.write_to_png(&mut png).is_err() {
        return std::ptr::null_mut();
    }

    png.shrink_to_fit();
    let len = png.len();
    let ptr = png.as_mut_ptr();
    std::mem::forget(png);
    unsafe { *out_len = len };
    ptr
}

/// Free a buffer from [`tvmv_card_render_png`].
///
/// # Safety
/// `ptr`/`len` must be exactly what that call returned, and only freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tvmv_card_free(ptr: *mut c_uchar, len: usize) {
    if ptr.is_null() {
        return;
    }
    // `shrink_to_fit` before `forget` makes capacity == len, so this is the
    // allocation that was leaked.
    drop(unsafe { Vec::from_raw_parts(ptr, len, len) });
}
