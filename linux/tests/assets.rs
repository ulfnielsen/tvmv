//! Asset routing, confinement, and MIME tests.

use std::fs;
use std::path::{Path, PathBuf};

use tvmv::assets::{Asset, AssetError, AssetRouter, WebSource, mime_type};

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

/// The file a resolve landed on. Every fixture router reads from a directory,
/// so an embedded result here would mean the router picked the wrong source.
fn file(r: &AssetRouter, uri: &str) -> Result<PathBuf, AssetError> {
    match r.resolve(uri) {
        Ok(Asset::File(path)) => Ok(path),
        Ok(Asset::Bytes(_)) => panic!("expected a file, got embedded bytes: {uri}"),
        Err(e) => Err(e),
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
    assert_eq!(file(&r, "tvmv-asset://app/app.css").unwrap(), f.root.join("app/app.css"));
    assert_eq!(
        file(&r, "tvmv-asset://app/vendor/katex/katex.min.js").unwrap(),
        f.root.join("app/vendor/katex/katex.min.js")
    );
}

#[test]
fn doc_host_serves_the_document_directory() {
    let f = Fixture::new("doc-host");
    let r = f.router();
    assert_eq!(file(&r, "tvmv-asset://doc/img.png").unwrap(), f.root.join("doc/img.png"));
    assert_eq!(file(&r, "tvmv-asset://doc/sub/deep.png").unwrap(), f.root.join("doc/sub/deep.png"));
}

#[test]
fn unknown_host_is_rejected() {
    let f = Fixture::new("unknown-host");
    assert_eq!(
        file(&f.router(), "tvmv-asset://elsewhere/app.css"),
        Err(AssetError::UnknownHost("elsewhere".into()))
    );
}

#[test]
fn doc_host_without_a_document_fails_cleanly() {
    let f = Fixture::new("no-doc");
    assert_eq!(file(&f.app_only(), "tvmv-asset://doc/img.png"), Err(AssetError::NoDocumentDirectory));
}

#[test]
fn document_directory_can_be_changed_and_cleared() {
    let f = Fixture::new("swap-doc");
    let mut r = f.app_only();
    assert_eq!(file(&r, "tvmv-asset://doc/img.png"), Err(AssetError::NoDocumentDirectory));

    r.set_document_directory(Some(f.root.join("doc")));
    assert!(file(&r, "tvmv-asset://doc/img.png").is_ok());

    r.set_document_directory(None);
    assert_eq!(file(&r, "tvmv-asset://doc/img.png"), Err(AssetError::NoDocumentDirectory));
}

// --- malformed input -------------------------------------------------------

#[test]
fn wrong_scheme_is_rejected() {
    let f = Fixture::new("wrong-scheme");
    assert_eq!(file(&f.router(), "https://app/app.css"), Err(AssetError::MalformedUrl));
    assert_eq!(file(&f.router(), "not a url"), Err(AssetError::MalformedUrl));
}

#[test]
fn missing_file_is_not_found() {
    let f = Fixture::new("missing");
    assert_eq!(file(&f.router(), "tvmv-asset://app/nope.css"), Err(AssetError::NotFound));
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
    assert_eq!(file(&r, "tvmv-asset://doc/%2E%2E/secret.txt"), Err(AssetError::PathTraversal));
    assert_eq!(file(&r, "tvmv-asset://doc/sub/%2e%2e/%2e%2e/secret.txt"), Err(AssetError::PathTraversal));
}

/// An absolute path would make `join` discard the base entirely.
#[test]
fn absolute_path_is_rejected() {
    let f = Fixture::new("absolute");
    assert_eq!(file(&f.router(), "tvmv-asset://doc//etc/passwd"), Err(AssetError::PathTraversal));
}

/// Interior `..` that stays inside the base is fine — it is a legal relative path.
#[test]
fn traversal_that_stays_inside_is_allowed() {
    let f = Fixture::new("inside-traversal");
    assert_eq!(
        file(&f.router(), "tvmv-asset://doc/sub/../img.png").unwrap(),
        f.root.join("doc/img.png")
    );
}

#[test]
fn the_base_directory_itself_is_allowed() {
    let f = Fixture::new("base-itself");
    assert!(file(&f.router(), "tvmv-asset://app/").is_ok());
}

/// A sibling directory sharing a name prefix must not pass the prefix check
/// ("/app" must not match "/app-evil").
#[test]
fn sibling_with_shared_name_prefix_is_rejected() {
    let f = Fixture::new("prefix");
    fs::create_dir_all(f.root.join("app-evil")).unwrap();
    fs::write(f.root.join("app-evil/x.css"), "x").unwrap();
    assert_eq!(
        file(&f.router(), "tvmv-asset://app/../app-evil/x.css"),
        Err(AssetError::PathTraversal)
    );
}

// --- percent decoding ------------------------------------------------------

#[test]
fn spaces_in_filenames_are_decoded() {
    let f = Fixture::new("spaces");
    assert_eq!(
        file(&f.router(), "tvmv-asset://doc/my%20file.png").unwrap(),
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


// --- the embedded web layer ------------------------------------------------
//
// The shipping configuration: `build.rs` compiles the shared web layer in, so
// these assert against what the binary actually carries.

fn embedded() -> AssetRouter {
    AssetRouter::new(WebSource::Embedded)
}

fn bytes(uri: &str) -> Result<&'static [u8], AssetError> {
    match embedded().resolve(uri) {
        Ok(Asset::Bytes(bytes)) => Ok(bytes),
        Ok(Asset::File(path)) => panic!("expected embedded bytes, got {}: {uri}", path.display()),
        Err(e) => Err(e),
    }
}

/// The four the shell cannot start without, and one vendored file from a
/// nested directory — the case a flat table would get wrong.
#[test]
fn the_web_layer_is_in_the_binary() {
    for uri in [
        "tvmv-asset://app/template.html",
        "tvmv-asset://app/app.css",
        "tvmv-asset://app/boot.js",
        "tvmv-asset://app/editor.html",
        "tvmv-asset://app/vendor/katex/katex.min.css",
    ] {
        let content = bytes(uri).unwrap_or_else(|e| panic!("{uri}: {e}"));
        assert!(!content.is_empty(), "{uri} is embedded but empty");
    }
}

/// Not a smoke test of one file: the whole layer has to be there, or a lazy
/// pass fails at runtime on a machine with nothing on disk to fall back to.
#[test]
fn the_embedded_set_is_the_whole_web_layer() {
    let dir = tvmv::resources::web_dir().expect("a web layer on disk to compare against");
    let mut missing = Vec::new();
    let mut checked = 0;
    for entry in walkdir(&dir) {
        let key = entry.strip_prefix(&dir).unwrap().to_str().unwrap().to_string();
        // Build tooling, deliberately not served.
        if key == "vendor.fish" || key == "vendor.json" {
            continue;
        }
        checked += 1;
        let uri = format!("tvmv-asset://app/{key}");
        match bytes(&uri) {
            Ok(embedded) => {
                let on_disk = fs::read(&entry).unwrap();
                if embedded != on_disk.as_slice() {
                    missing.push(format!("{key} (stale: {} vs {} bytes)", embedded.len(), on_disk.len()));
                }
            }
            Err(e) => missing.push(format!("{key} ({e})")),
        }
    }
    assert!(checked > 60, "only {checked} files walked — is the web layer there?");
    assert!(missing.is_empty(), "not embedded, or out of date: {missing:#?}");
}

#[test]
fn a_missing_embedded_asset_is_not_found() {
    assert_eq!(bytes("tvmv-asset://app/nope.css"), Err(AssetError::NotFound));
    // A directory is not an asset: there is nothing to stream for it.
    assert_eq!(bytes("tvmv-asset://app/vendor"), Err(AssetError::NotFound));
    assert_eq!(bytes("tvmv-asset://app/"), Err(AssetError::NotFound));
}

/// Same answers as the directory source for the same URLs, so switching source
/// cannot change what a document is allowed to reach.
#[test]
fn embedded_rejects_traversal_and_absolute_paths() {
    for uri in [
        "tvmv-asset://app/../secret.txt",
        "tvmv-asset://app/%2E%2E/secret.txt",
        "tvmv-asset://app/vendor/../../../etc/passwd",
        "tvmv-asset://app//etc/passwd",
    ] {
        assert_eq!(bytes(uri), Err(AssetError::PathTraversal), "not rejected: {uri}");
    }
}

/// Interior `..` that stays inside is a legal relative path — a vendored
/// stylesheet may reference `../fonts/x.woff2`.
#[test]
fn embedded_allows_interior_dotdot() {
    let direct = bytes("tvmv-asset://app/vendor/katex/katex.min.css").unwrap();
    let around = bytes("tvmv-asset://app/vendor/katex/fonts/../katex.min.css").unwrap();
    assert_eq!(direct, around);
}

#[test]
fn embedded_still_routes_by_host() {
    assert_eq!(
        embedded().resolve("tvmv-asset://doc/img.png"),
        Err(AssetError::NoDocumentDirectory)
    );
    assert_eq!(
        embedded().resolve("tvmv-asset://elsewhere/app.css"),
        Err(AssetError::UnknownHost("elsewhere".into()))
    );
}

/// A document's own images keep coming from disk while the app layer does not.
#[test]
fn embedded_app_and_on_disk_document_coexist() {
    let f = Fixture::new("embedded-plus-doc");
    let mut r = embedded();
    r.set_document_directory(Some(f.root.join("doc")));

    assert!(matches!(r.resolve("tvmv-asset://app/boot.js"), Ok(Asset::Bytes(_))));
    assert_eq!(file(&r, "tvmv-asset://doc/img.png").unwrap(), f.root.join("doc/img.png"));
}

fn walkdir(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for entry in fs::read_dir(dir).unwrap().flatten() {
        let path = entry.path();
        if path.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with('.')) {
            continue;
        }
        if path.is_dir() {
            found.extend(walkdir(&path));
        } else {
            found.push(path);
        }
    }
    found
}
