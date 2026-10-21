//! Block-image loading rules, from the Swift `DocumentImageTests`.

use std::path::{Path, PathBuf};

use gtk4::gdk_pixbuf::{Colorspace, Pixbuf};
use tvmv::images::{self, ImageSource, data_url, decode, download, image_source, paragraph_padding, pasted_name, read_local};

struct Folder(PathBuf);

impl Folder {
    fn new(name: &str) -> Folder {
        let p = std::env::temp_dir().join(format!("tvmv-images-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(p.join("img")).unwrap();
        Folder(p)
    }
    fn png(&self, name: &str, w: i32, h: i32) -> PathBuf {
        let path = self.0.join(name);
        let pixbuf = Pixbuf::new(Colorspace::Rgb, true, 8, w, h).unwrap();
        pixbuf.fill(0xff0000ff);
        pixbuf.savev(&path, "png", &[]).unwrap();
        path
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn addresses_resolve_like_the_web_reader() {
    let doc = Path::new("/docs/guide/readme.md");
    let resolve = |s: &str| image_source(s, Some(doc));
    let local = |p: &str| Some(ImageSource::Local { path: p.into(), folder: "/docs/guide".into() });
    assert_eq!(resolve("img/a b.png"), local("/docs/guide/img/a b.png"));
    assert_eq!(resolve("img/a%20b.png"), local("/docs/guide/img/a b.png"));
    assert_eq!(resolve("img/../a.png"), local("/docs/guide/a.png"));
    assert_eq!(resolve("https://e.x/p.png"), Some(ImageSource::Remote("https://e.x/p.png".into())));
    assert_eq!(resolve("http://e.x/p.png"), Some(ImageSource::Remote("http://e.x/p.png".into())));
    assert!(matches!(resolve("data:image/png;base64,iVBORw0KGgo="), Some(ImageSource::Data(_))));
    assert_eq!(resolve("../shot.png"), None, "outside the document's folder");
    assert_eq!(resolve("/etc/hosts"), None, "absolute paths");
    assert_eq!(resolve("file:///tmp/p.png"), None, "file URLs");
    assert_eq!(resolve("javascript:alert(1)"), None);
    assert_eq!(image_source("img/a.png", None), None, "a relative path needs a document folder");
}

#[test]
fn local_reads_stay_in_the_folder_and_under_the_limit() {
    let f = Folder::new("local");
    let png = f.png("big.png", 200, 100);
    let size = std::fs::metadata(&png).unwrap().len() as usize;
    assert_eq!(read_local(&png, &f.0, size).map(|d| d.len()), Some(size));
    assert_eq!(read_local(&png, &f.0, size - 1), None, "over the byte limit");

    let outside = std::env::temp_dir().join(format!("tvmv-outside-{}.png", std::process::id()));
    std::fs::copy(&png, &outside).unwrap();
    std::os::unix::fs::symlink(&outside, f.0.join("link.png")).unwrap();
    assert_eq!(read_local(&f.0.join("link.png"), &f.0, images::MAX_BYTES), None, "a symlink out of the folder");
    let _ = std::fs::remove_file(&outside);

    std::os::unix::fs::symlink("/dev/zero", f.0.join("zero.png")).unwrap();
    assert_eq!(read_local(&f.0.join("zero.png"), &f.0, images::MAX_BYTES), None, "a device");
    assert_eq!(read_local(&f.0.join("img"), &f.0, images::MAX_BYTES), None, "a directory");
}

#[test]
fn decoding_fails_closed_on_the_pixel_limit() {
    let f = Folder::new("decode");
    let data = std::fs::read(f.png("wide.png", 200, 100)).unwrap();
    let d = decode(&data, 20_000).expect("200×100 fits 20,000 pixels");
    assert_eq!((d.width, d.height, d.has_alpha), (200, 100, true));
    assert!(decode(&data, 10_000).is_none(), "200×100 is over 10,000 pixels");

    let svg = |side: u32| {
        format!("<svg xmlns='http://www.w3.org/2000/svg' width='{side}' height='{side}'><rect width='10' height='10'/></svg>")
    };
    assert!(decode(svg(20).as_bytes(), 10_000).is_some(), "a small SVG (a badge) loads");
    assert!(decode(svg(5000).as_bytes(), 10_000).is_none(), "a vector image is held to the same limit");
    assert!(decode(b"not an image at all", 10_000).is_none());
}

#[test]
fn data_urls_and_downloads_are_capped() {
    // A 1×1 PNG.
    let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
    let bytes = data_url(&format!("data:image/png;base64,{png}"), 1000).unwrap();
    assert_eq!(&bytes[1..4], b"PNG");
    assert!(decode(&bytes, 10).is_some());
    assert_eq!(data_url(&format!("data:image/png;base64,{png}"), 10), None);
    assert_eq!(data_url("data:text/plain,a%20b", 10).as_deref(), Some(&b"a b"[..]));

    // GIO streams file URIs too; the cap is the same code remote images use.
    let f = Folder::new("download");
    let path = f.png("big.png", 200, 100);
    let size = std::fs::metadata(&path).unwrap().len() as usize;
    let uri = format!("file://{}", path.display());
    assert_eq!(download(&uri, size).map(|d| d.len()), Some(size));
    assert_eq!(download(&uri, size - 1), None);
}

#[test]
fn pasted_images_get_their_own_file_and_paragraph() {
    let f = Folder::new("paste");
    let doc = f.0.join("doc.md");
    assert_eq!(pasted_name(&doc, &f.0.join("img"), "20261021-120000"), "doc-20261021-120000.png");
    std::fs::write(f.0.join("img/doc-20261021-120000.png"), "x").unwrap();
    assert_eq!(pasted_name(&doc, &f.0.join("img"), "20261021-120000"), "doc-20261021-120000-2.png");

    assert_eq!(paragraph_padding("Before.\n", 7..7), ("\n\n", ""));
    assert_eq!(paragraph_padding("", 0..0), ("", ""));
    assert_eq!(paragraph_padding("a\n\nb\n", 3..3), ("", "\n\n"));
    assert_eq!(paragraph_padding("a\nb", 2..2), ("\n", "\n\n"));
}
