//! Asset routing, confinement, and MIME tests.

use std::fs;
use std::path::{Path, PathBuf};

use tvmv::assets::{AssetError, AssetRouter, mime_type};

/// A throwaway tree: `<root>/app/{app.css,vendor/katex/katex.min.js}` and
/// `<root>/doc/{img.png,"my file.png",sub/deep.png}`, plus `<root>/secret.txt`
/// outside both bases.
struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir().join("tvmv-asset-tests").join(name);
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("app/vendor/katex")).unwrap();
        fs::create_dir_all(root.join("doc/sub")).unwrap();
        fs::write(root.join("app/app.css"), "body{}").unwrap();
        fs::write(root.join("app/vendor/katex/katex.min.js"), "//").unwrap();
        fs::write(root.join("doc/img.png"), [0u8]).unwrap();
        fs::write(root.join("doc/my file.png"), [0u8]).unwrap();
        fs::write(root.join("doc/sub/deep.png"), [0u8]).unwrap();
        fs::write(root.join("secret.txt"), "secret").unwrap();
        Self { root }
    }

    fn router(&self) -> AssetRouter {
        let mut r = AssetRouter::new(self.root.join("app"));
        r.set_document_directory(Some(self.root.join("doc")));
        r
    }

    fn app_only(&self) -> AssetRouter {
        AssetRouter::new(self.root.join("app"))
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

// --- host routing ----------------------------------------------------------

#[test]
fn app_host_serves_bundled_resources() {
    let f = Fixture::new("app-host");
    let r = f.router();
    assert_eq!(r.resolve("tvmv-asset://app/app.css").unwrap(), f.root.join("app/app.css"));
    assert_eq!(
        r.resolve("tvmv-asset://app/vendor/katex/katex.min.js").unwrap(),
        f.root.join("app/vendor/katex/katex.min.js")
    );
}

#[test]
fn doc_host_serves_the_document_directory() {
    let f = Fixture::new("doc-host");
    let r = f.router();
    assert_eq!(r.resolve("tvmv-asset://doc/img.png").unwrap(), f.root.join("doc/img.png"));
    assert_eq!(r.resolve("tvmv-asset://doc/sub/deep.png").unwrap(), f.root.join("doc/sub/deep.png"));
}

#[test]
fn unknown_host_is_rejected() {
    let f = Fixture::new("unknown-host");
    assert_eq!(
        f.router().resolve("tvmv-asset://elsewhere/app.css"),
        Err(AssetError::UnknownHost("elsewhere".into()))
    );
}

#[test]
fn doc_host_without_a_document_fails_cleanly() {
    let f = Fixture::new("no-doc");
    assert_eq!(f.app_only().resolve("tvmv-asset://doc/img.png"), Err(AssetError::NoDocumentDirectory));
}

#[test]
fn document_directory_can_be_changed_and_cleared() {
    let f = Fixture::new("swap-doc");
    let mut r = f.app_only();
    assert_eq!(r.resolve("tvmv-asset://doc/img.png"), Err(AssetError::NoDocumentDirectory));

    r.set_document_directory(Some(f.root.join("doc")));
    assert!(r.resolve("tvmv-asset://doc/img.png").is_ok());

    r.set_document_directory(None);
    assert_eq!(r.resolve("tvmv-asset://doc/img.png"), Err(AssetError::NoDocumentDirectory));
}

// --- malformed input -------------------------------------------------------

#[test]
fn wrong_scheme_is_rejected() {
    let f = Fixture::new("wrong-scheme");
    assert_eq!(f.router().resolve("https://app/app.css"), Err(AssetError::MalformedUrl));
    assert_eq!(f.router().resolve("not a url"), Err(AssetError::MalformedUrl));
}

#[test]
fn missing_file_is_not_found() {
    let f = Fixture::new("missing");
    assert_eq!(f.router().resolve("tvmv-asset://app/nope.css"), Err(AssetError::NotFound));
}

// --- path traversal --------------------------------------------------------

#[test]
fn dotdot_traversal_is_rejected() {
    let f = Fixture::new("traversal");
    let r = f.router();
    for uri in [
        "tvmv-asset://doc/../secret.txt",
        "tvmv-asset://doc/sub/../../secret.txt",
        "tvmv-asset://app/../secret.txt",
        "tvmv-asset://doc/../../../../../../etc/passwd",
    ] {
        assert_eq!(r.resolve(uri), Err(AssetError::PathTraversal), "not confined: {uri}");
    }
}

/// Percent-encoded traversal must be caught *after* decoding, not before.
#[test]
fn percent_encoded_traversal_is_rejected() {
    let f = Fixture::new("encoded-traversal");
    let r = f.router();
    assert_eq!(r.resolve("tvmv-asset://doc/%2E%2E/secret.txt"), Err(AssetError::PathTraversal));
    assert_eq!(r.resolve("tvmv-asset://doc/sub/%2e%2e/%2e%2e/secret.txt"), Err(AssetError::PathTraversal));
}

/// An absolute path would make `join` discard the base entirely.
#[test]
fn absolute_path_is_rejected() {
    let f = Fixture::new("absolute");
    assert_eq!(f.router().resolve("tvmv-asset://doc//etc/passwd"), Err(AssetError::PathTraversal));
}

/// Interior `..` that stays inside the base is fine — it is a legal relative path.
#[test]
fn traversal_that_stays_inside_is_allowed() {
    let f = Fixture::new("inside-traversal");
    assert_eq!(
        f.router().resolve("tvmv-asset://doc/sub/../img.png").unwrap(),
        f.root.join("doc/img.png")
    );
}

#[test]
fn the_base_directory_itself_is_allowed() {
    let f = Fixture::new("base-itself");
    assert!(f.router().resolve("tvmv-asset://app/").is_ok());
}

/// A sibling directory sharing a name prefix must not pass the prefix check
/// ("/app" must not match "/app-evil").
#[test]
fn sibling_with_shared_name_prefix_is_rejected() {
    let f = Fixture::new("prefix");
    fs::create_dir_all(f.root.join("app-evil")).unwrap();
    fs::write(f.root.join("app-evil/x.css"), "x").unwrap();
    assert_eq!(
        f.router().resolve("tvmv-asset://app/../app-evil/x.css"),
        Err(AssetError::PathTraversal)
    );
}

// --- percent decoding ------------------------------------------------------

#[test]
fn spaces_in_filenames_are_decoded() {
    let f = Fixture::new("spaces");
    assert_eq!(
        f.router().resolve("tvmv-asset://doc/my%20file.png").unwrap(),
        f.root.join("doc/my file.png")
    );
}

// --- MIME ------------------------------------------------------------------

/// The three the app cannot work without: WebKit ignores a stylesheet and
/// refuses a script served as octet-stream, silently.
#[test]
fn critical_mime_types() {
    assert_eq!(mime_type(Path::new("app.css")), "text/css");
    assert_eq!(mime_type(Path::new("boot.js")), "text/javascript");
    assert_eq!(mime_type(Path::new("KaTeX_Main-Regular.woff2")), "font/woff2");
}

#[test]
fn mime_covers_the_vendored_and_document_asset_set() {
    for (name, expected) in [
        ("editor.html", "text/html"),
        ("vendor.json", "application/json"),
        ("f.woff", "font/woff"),
        ("f.ttf", "font/ttf"),
        ("i.png", "image/png"),
        ("i.jpg", "image/jpeg"),
        ("i.jpeg", "image/jpeg"),
        ("i.gif", "image/gif"),
        ("i.svg", "image/svg+xml"),
        ("i.webp", "image/webp"),
        ("readme.md", "text/markdown"),
    ] {
        assert_eq!(mime_type(Path::new(name)), expected, "{name}");
    }
}

#[test]
fn mime_is_case_insensitive_and_falls_back() {
    assert_eq!(mime_type(Path::new("IMAGE.PNG")), "image/png");
    assert_eq!(mime_type(Path::new("Style.CSS")), "text/css");
    assert_eq!(mime_type(Path::new("noextension")), "application/octet-stream");
    assert_eq!(mime_type(Path::new("archive.xyz")), "application/octet-stream");
}
