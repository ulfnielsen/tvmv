//! Block images for the native view: where an address may point, reading
//! and downloading within limits, and decoding within a pixel budget. Ports
//! of `DocumentTextView.imageURL`, `readLocal`, `download` and `decode`.
//!
//! A document is untrusted input. As in the web reader, local images come
//! only from inside the document's folder (no "../", absolute paths or file
//! URLs, and not through a symlink that leaves it); http, https and data
//! URLs load as written. What one image may cost is capped twice: in bytes
//! read, and in pixels decoded.

use std::io::Read;
use std::path::{Component, Path, PathBuf};

use gtk4::gdk_pixbuf::PixbufLoader;
use gtk4::gio;
use gtk4::prelude::*;

/// Default caps, as on macOS.
pub const MAX_BYTES: usize = 50_000_000;
pub const MAX_PIXELS: u64 = 100_000_000;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ImageSource {
    /// A file inside the document's folder (not yet checked for symlinks).
    Local { path: PathBuf, folder: PathBuf },
    /// http or https.
    Remote(String),
    /// A `data:` URL.
    Data(String),
}

/// `path` with "." and ".." resolved lexically, as `standardizedFileURL`.
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// Where the image address `address`, written in the document at
/// `document`, may be loaded from; `None` when nowhere.
pub fn image_source(address: &str, document: Option<&Path>) -> Option<ImageSource> {
    if let Some((scheme, _)) = address.split_once(':')
        && !scheme.is_empty()
        && scheme.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
        && scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
    {
        return match scheme.to_ascii_lowercase().as_str() {
            "http" | "https" => Some(ImageSource::Remote(address.to_string())),
            "data" => Some(ImageSource::Data(address.to_string())),
            _ => None,
        };
    }
    let path = percent_encoding::percent_decode_str(address).decode_utf8().ok()?.into_owned();
    if path.starts_with('/') {
        return None;
    }
    let folder = normalize(document?.parent()?);
    let candidate = normalize(&folder.join(path));
    candidate.starts_with(&folder).then_some(ImageSource::Local { path: candidate, folder })
}

/// Read a local image: a regular file, still inside `folder` once symlinks
/// are resolved, and no larger than `limit` bytes.
pub fn read_local(path: &Path, folder: &Path, limit: usize) -> Option<Vec<u8>> {
    let real = path.canonicalize().ok()?;
    if !real.starts_with(folder.canonicalize().ok()?) {
        return None;
    }
    let meta = std::fs::metadata(&real).ok()?;
    if !meta.is_file() || meta.len() > limit as u64 {
        return None;
    }
    // The size can change between the check and the read: read one byte
    // more than the limit at most.
    let mut data = Vec::new();
    std::fs::File::open(&real).ok()?.take(limit as u64 + 1).read_to_end(&mut data).ok()?;
    (data.len() <= limit).then_some(data)
}

/// Fetch at most `limit` bytes from `uri` (blocking: call it off the main
/// thread); `None` if there is more, or on any error. GIO handles the
/// scheme, so http needs gvfs, as every GNOME and KDE desktop has.
pub fn download(uri: &str, limit: usize) -> Option<Vec<u8>> {
    let stream = gio::File::for_uri(uri).read(gio::Cancellable::NONE).ok()?;
    let mut data = Vec::new();
    loop {
        let chunk = stream.read_bytes(64 * 1024, gio::Cancellable::NONE).ok()?;
        if chunk.is_empty() {
            return Some(data);
        }
        data.extend_from_slice(&chunk);
        if data.len() > limit {
            return None;
        }
    }
}

/// The bytes of a `data:` URL (base64 or percent-encoded), within `limit`.
pub fn data_url(url: &str, limit: usize) -> Option<Vec<u8>> {
    // `image_source` has checked the scheme, in any case.
    let (meta, payload) = url.get(5..)?.split_once(',')?;
    let data = if meta.ends_with(";base64") {
        let clean: String = payload.chars().filter(|c| !c.is_whitespace()).collect();
        let clean = percent_encoding::percent_decode_str(&clean).decode_utf8().ok()?.into_owned();
        gtk4::glib::base64_decode(&clean)
    } else {
        percent_encoding::percent_decode_str(payload).collect()
    };
    (data.len() <= limit).then_some(data)
}

/// Decoded pixels, ready for a `gdk::MemoryTexture`: unpremultiplied RGB
/// or RGBA, 8 bits a channel. Unlike a `Pixbuf`, it can cross threads.
pub struct Decoded {
    pub width: i32,
    pub height: i32,
    pub stride: usize,
    pub has_alpha: bool,
    pub pixels: gtk4::glib::Bytes,
}

impl Decoded {
    pub fn texture(&self) -> gtk4::gdk::Texture {
        let format =
            if self.has_alpha { gtk4::gdk::MemoryFormat::R8g8b8a8 } else { gtk4::gdk::MemoryFormat::R8g8b8 };
        gtk4::gdk::MemoryTexture::new(self.width, self.height, format, &self.pixels, self.stride).upcast()
    }
}

/// Decode an image of at most `max_pixels`, failing closed: the decoder
/// reports the size before decoding, and anything larger is refused
/// unrendered. (GdkPixbuf decodes the first frame of a multi-frame file
/// only, so the first frame's size is the whole cost.) Vector images are
/// held to the same limit at their declared size.
pub fn decode(data: &[u8], max_pixels: u64) -> Option<Decoded> {
    let loader = PixbufLoader::new();
    let too_big = std::rc::Rc::new(std::cell::Cell::new(false));
    {
        let too_big = std::rc::Rc::clone(&too_big);
        loader.connect_size_prepared(move |loader, w, h| {
            if w <= 0 || h <= 0 || (w as u64) * (h as u64) > max_pixels {
                too_big.set(true);
                // Stop the decoder doing the work: a 1×1 render, discarded.
                loader.set_size(1, 1);
            }
        });
    }
    let written = loader.write(data).is_ok();
    let closed = loader.close().is_ok();
    if !written || !closed || too_big.get() {
        return None;
    }
    let pixbuf = loader.pixbuf()?;
    Some(Decoded {
        width: pixbuf.width(),
        height: pixbuf.height(),
        stride: pixbuf.rowstride() as usize,
        has_alpha: pixbuf.has_alpha(),
        pixels: pixbuf.read_pixel_bytes(),
    })
}

/// Load the image at `source`: read or fetch it within `max_bytes`, decode
/// it within `max_pixels`. Blocking.
pub fn load(source: &ImageSource, max_bytes: usize, max_pixels: u64) -> Option<Decoded> {
    let data = match source {
        ImageSource::Local { path, folder } => read_local(path, folder, max_bytes)?,
        ImageSource::Remote(uri) => download(uri, max_bytes)?,
        ImageSource::Data(url) => data_url(url, max_bytes)?,
    };
    decode(&data, max_pixels)
}

/// The file name for an image pasted into `document`: `<stem>-<stamp>.png`,
/// or `-2`, `-3`, … when that is taken in `folder`.
pub fn pasted_name(document: &Path, folder: &Path, stamp: &str) -> String {
    let stem = document.file_stem().map_or_else(|| "image".into(), |s| s.to_string_lossy().into_owned());
    let base = format!("{stem}-{stamp}");
    let mut name = format!("{base}.png");
    let mut n = 2;
    while folder.join(&name).exists() {
        name = format!("{base}-{n}.png");
        n += 1;
    }
    name
}

/// The text to insert for a pasted image at `at` in `text`: on its own
/// paragraph, so it shows as the picture. Returns (before, after).
pub fn paragraph_padding(text: &str, at: std::ops::Range<usize>) -> (&'static str, &'static str) {
    let b = text.as_bytes();
    let ch = |i: isize| (i >= 0 && (i as usize) < b.len()).then(|| b[i as usize]);
    let (s, e) = (at.start as isize, at.end as isize);
    let before = if s == 0 || (ch(s - 1) == Some(b'\n') && ch(s - 2) == Some(b'\n')) {
        ""
    } else if ch(s - 1) == Some(b'\n') {
        "\n"
    } else {
        "\n\n"
    };
    let after = if at.end >= b.len() || (ch(e) == Some(b'\n') && ch(e + 1).is_none_or(|c| c == b'\n')) {
        ""
    } else if ch(e) == Some(b'\n') {
        "\n"
    } else {
        "\n\n"
    };
    (before, after)
}
