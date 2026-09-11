//! The preview web view and its bridge to the shared web layer.
//!
//! Implements the three seams `boot.js` expects, against WebKitGTK instead of
//! WKWebView:
//!
//!   1. `tvmv-asset://` — `register_uri_scheme` in place of `WKURLSchemeHandler`
//!   2. JS -> native — `register_script_message_handler("tvmv")`. The JS side is
//!      **unchanged**: WebKitGTK exposes the same `window.webkit.messageHandlers`
//!      object WKWebView does, so `boot.js` needs no port.
//!   3. native -> JS — `evaluate_javascript` in place of `callAsyncJavaScript`
//!
//! Message vocabulary matches `PreviewBridge.swift`: inbound `outline`,
//! `renderComplete`, `sourceClick`, `error`.

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};

use gtk4::gio;
use gtk4::prelude::*;
use webkit6::prelude::*;
use webkit6::javascriptcore;
use webkit6::{URISchemeRequest, UserContentManager, WebContext, WebView};

use crate::assets::{AssetRouter, SCHEME, mime_type};
use crate::js;

/// One entry from the document outline, matching `OutlineItem.swift`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutlineItem {
    pub level: i64,
    pub title: String,
    pub anchor: String,
}

/// What the preview page reports back.
#[derive(Debug, Clone)]
pub enum PreviewMessage {
    Outline(Vec<OutlineItem>),
    RenderComplete,
    SourceClick { line: i64 },
    Error(String),
}

/// Per-web-view document directories for the `tvmv-asset://` scheme.
///
/// The scheme is registered on the **shared default** `WebContext`, and a
/// context accepts one handler per scheme — so registering per window would mean
/// the newest window's handler served every window, and `tvmv-asset://doc/`
/// would resolve relative images against the wrong document. One handler looks
/// the requesting view up here instead (`URISchemeRequest::web_view`).
///
/// GTK is single-threaded, so thread-local is the right scope.
#[derive(Default)]
struct SchemeRegistry {
    /// The bundled web layer, identical for every view.
    app_base: Option<PathBuf>,
    /// Document directory per view. Views compare by pointer, and the count is
    /// one or two per window, so a vector beats hashing an object.
    documents: Vec<(WebView, Option<PathBuf>)>,
}

thread_local! {
    static REGISTRY: RefCell<SchemeRegistry> = RefCell::new(SchemeRegistry::default());
    static SCHEME_REGISTERED: Cell<bool> = const { Cell::new(false) };
}

/// Register the asset scheme on the default context, exactly once per process.
fn ensure_scheme_registered(context: &WebContext, app_base: &Path) {
    REGISTRY.with(|r| r.borrow_mut().app_base = Some(app_base.to_path_buf()));

    if SCHEME_REGISTERED.with(|f| f.replace(true)) {
        return;
    }
    context.register_uri_scheme(SCHEME, serve);
}

fn set_document_directory_for(view: &WebView, dir: Option<PathBuf>) {
    REGISTRY.with(|r| {
        let mut registry = r.borrow_mut();
        match registry.documents.iter_mut().find(|(v, _)| v == view) {
            Some(entry) => entry.1 = dir,
            None => registry.documents.push((view.clone(), dir)),
        }
    });
}

fn forget_view(view: &WebView) {
    REGISTRY.with(|r| r.borrow_mut().documents.retain(|(v, _)| v != view));
}

/// Build the router for whichever view issued this request.
fn router_for(view: Option<&WebView>) -> Option<AssetRouter> {
    REGISTRY.with(|r| {
        let registry = r.borrow();
        let mut router = AssetRouter::new(registry.app_base.clone()?);
        if let Some(view) = view
            && let Some((_, dir)) = registry.documents.iter().find(|(v, _)| v == view)
        {
            router.set_document_directory(dir.clone());
        }
        Some(router)
    })
}

pub struct Preview {
    pub web_view: WebView,
}

impl Preview {
    /// Build a web view wired to the shared web layer.
    ///
    /// `on_message` receives everything the page posts. It runs on the GTK main
    /// thread, so it can touch widgets directly.
    pub fn new(
        web_dir: &Path,
        on_message: impl Fn(PreviewMessage) + 'static,
    ) -> Self {
        let context = WebContext::default().expect("a default WebKit context");

        // Seam 1: the asset scheme, registered once for the whole process.
        ensure_scheme_registered(&context, web_dir);

        // Seam 2: JS -> native.
        let content_manager = UserContentManager::new();
        content_manager.register_script_message_handler("tvmv", None);
        content_manager.connect_script_message_received(Some("tvmv"), move |_, value| {
            if let Some(message) = parse_message(value) {
                on_message(message);
            }
        });

        let web_view = WebView::builder()
            .web_context(&context)
            .user_content_manager(&content_manager)
            .build();

        tune_for_reading(&web_view);
        set_document_directory_for(&web_view, None);

        Self { web_view }
    }

    /// Load the template page. `boot.js` is callable once loading finishes.
    pub fn load_template(&self) {
        self.web_view.load_uri(&format!("{SCHEME}://app/template.html"));
    }

    /// Keep the scheme handler's document directory in sync for this view.
    pub fn set_document_directory(&self, dir: Option<PathBuf>) {
        set_document_directory_for(&self.web_view, dir);
    }

    /// Paint the view's own background to match the page.
    ///
    /// WebKitGTK defaults a web view to opaque white. Against the warm paper
    /// theme that shows as a cold flash on load, on overscroll, and during
    /// resize — before any of the page's own CSS applies.
    pub fn set_background(&self, rgb: (f64, f64, f64)) {
        let colour = gtk4::gdk::RGBA::new(rgb.0 as f32, rgb.1 as f32, rgb.2 as f32, 1.0);
        self.web_view.set_background_color(&colour);
    }

    /// Seam 3: native -> JS.
    pub fn eval(&self, script: &str) {
        self.web_view.evaluate_javascript(
            script,
            None,
            None,
            gio::Cancellable::NONE,
            |_| {},
        );
    }

    /// Evaluate `script` and hand its value back as JSON.
    ///
    /// `find`/`findNext` return `{count, index}` and the chrome tint needs the
    /// page's computed background, so unlike `eval` these results matter.
    pub fn eval_json(
        &self,
        script: &str,
        on_result: impl FnOnce(Option<serde_json::Value>) + 'static,
    ) {
        self.web_view.evaluate_javascript(
            script,
            None,
            None,
            gio::Cancellable::NONE,
            move |result| {
                let value = result.ok().and_then(|v| v.to_json(0)).and_then(|json| {
                    serde_json::from_str::<serde_json::Value>(json.as_str()).ok()
                });
                on_result(value);
            },
        );
    }

    /// `window.tvmv.render(bodyHTML, docBaseHref)`.
    ///
    /// The Swift side passes the arguments natively via `callAsyncJavaScript`;
    /// WebKitGTK has no argument-passing equivalent, so the HTML is encoded as a
    /// JS string literal instead. Same result, one extra encode of a
    /// document-sized string.
    pub fn render(&self, body_html: &str, doc_base_href: &str) {
        self.eval(&format!(
            "window.tvmv.render({}, {});",
            js::literal(body_html),
            js::literal(doc_base_href)
        ));
    }

    pub fn apply_style(&self, style_json: &str) {
        self.eval(&format!("window.tvmv.applyStyle({});", js::literal(style_json)));
    }

    pub fn scroll_to_anchor(&self, anchor: &str) {
        self.eval(&format!("window.tvmv.scrollToAnchor({});", crate::js::literal(anchor)));
    }

    /// Align the preview's top with an editor line (editor scrolled).
    pub fn scroll_to_source_line(&self, line: i64) {
        self.eval(&format!("window.tvmv.scrollToSourceLine({line});"));
    }

    /// Bring an editor line's block into view only if it is offscreen
    /// (cursor moved). Distinct from `scroll_to_source_line`, which always
    /// repositions.
    pub fn reveal_source_line(&self, line: i64) {
        self.eval(&format!("window.tvmv.revealSourceLine({line});"));
    }

    pub fn clear_find(&self) {
        self.eval("window.tvmv && window.tvmv.clearFind && window.tvmv.clearFind();");
    }

    pub fn apply_user_css(&self, css: &str) {
        self.eval(&format!("window.tvmv.applyUserCSS({});", js::literal(css)));
    }
}

/// Settings that matter for a document reader.
///
/// - **`ThreadedScrolling`** is off by default in WebKitGTK. It is the feature
///   that hands scrolling to a dedicated thread compositing a layer instead of
///   repainting the viewport on the main thread — i.e. the thing that makes
///   WKWebView feel the way it does on macOS. Off by default is easy to miss:
///   `WebKitFeature::is_default_value()` reports whether a feature is *at* its
///   default, not whether it is *on*, and reading the first as the second is how
///   this was overlooked the first time round. **It also core-dumps WebKit 2.52
///   when switched on**, so it stays off and is opt-IN only, for retesting on
///   future WebKitGTK releases.
/// - Smooth scrolling is already on by default here; setting it documents intent.
/// - `HardwareAccelerationPolicy::Always` does not stick on this build — the
///   getter reports `Never` immediately after the setter, on a fresh unattached
///   `Settings` as well as a live view. Kept as the correct request to make,
///   not because it was shown to help.
///
/// `TVMV_THREADED_SCROLLING=1` opts into the (currently crashing) first one, for
/// retesting with `--frame-bench` when WebKitGTK updates.
fn tune_for_reading(web_view: &WebView) {
    let Some(settings) = WebViewExt::settings(web_view) else { return };
    settings.set_hardware_acceleration_policy(webkit6::HardwareAccelerationPolicy::Always);
    settings.set_enable_smooth_scrolling(true);

    // Opt-in only: enabling this crashes the web process on WebKitGTK 2.52.
    if std::env::var("TVMV_THREADED_SCROLLING").as_deref() == Ok("1") {
        set_feature(&settings, "ThreadedScrolling", true);
    }
}

/// Toggle a WebKit runtime feature by identifier, if this build has it.
fn set_feature(settings: &webkit6::Settings, identifier: &str, enabled: bool) {
    let Some(features) = webkit6::Settings::all_features() else { return };
    for i in 0..features.length() {
        let Some(feature) = features.get(i) else { continue };
        if feature.identifier().is_some_and(|id| id == identifier) {
            settings.set_feature_enabled(&feature, enabled);
            return;
        }
    }
}

impl Drop for Preview {
    fn drop(&mut self) {
        forget_view(&self.web_view);
    }
}

/// Answer one `tvmv-asset://` request, routed for the requesting view.
fn serve(request: &URISchemeRequest) {
    let Some(uri) = request.uri() else {
        request.finish_error(&mut glib::Error::new(gio::IOErrorEnum::InvalidArgument, "missing URI"));
        return;
    };

    let Some(router) = router_for(request.web_view().as_ref()) else {
        request.finish_error(&mut glib::Error::new(
            gio::IOErrorEnum::NotFound,
            "asset scheme not configured",
        ));
        return;
    };

    match router.resolve(uri.as_str()) {
        Ok(path) => {
            let file = gio::File::for_path(&path);
            match file.read(gio::Cancellable::NONE) {
                Ok(stream) => {
                    let size = std::fs::metadata(&path).map(|m| m.len() as i64).unwrap_or(-1);
                    request.finish(&stream, size, Some(mime_type(&path)));
                }
                Err(e) => {
                    request.finish_error(&mut glib::Error::new(gio::IOErrorEnum::Failed, &e.to_string()));
                }
            }
        }
        Err(e) => {
            request.finish_error(&mut glib::Error::new(gio::IOErrorEnum::NotFound, &e.to_string()));
        }
    }
}

/// Decode one posted message. The page sends a JS object; the simplest faithful
/// route to Rust is the JSON the JSC value can already produce.
fn parse_message(value: &javascriptcore::Value) -> Option<PreviewMessage> {
    let json = value.to_json(0)?;
    let parsed: serde_json::Value = serde_json::from_str(json.as_str()).ok()?;

    match parsed.get("type")?.as_str()? {
        "outline" => {
            let items = parsed
                .get("items")
                .and_then(|i| i.as_array())
                .map(|entries| {
                    entries
                        .iter()
                        .filter_map(|entry| {
                            Some(OutlineItem {
                                level: entry.get("level")?.as_i64()?,
                                title: entry.get("title")?.as_str()?.to_string(),
                                anchor: entry.get("anchor")?.as_str()?.to_string(),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            Some(PreviewMessage::Outline(items))
        }
        "renderComplete" => Some(PreviewMessage::RenderComplete),
        "sourceClick" => Some(PreviewMessage::SourceClick { line: parsed.get("line")?.as_i64()? }),
        "error" => Some(PreviewMessage::Error(
            parsed.get("message").and_then(|m| m.as_str()).unwrap_or("Unknown error").to_string(),
        )),
        _ => None,
    }
}
