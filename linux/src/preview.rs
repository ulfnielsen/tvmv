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
use std::rc::Rc;

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
    /// A scroll position captured before a re-render, waiting to be put back.
    ///
    /// Lives here rather than in the window because it belongs to this view's
    /// page, and because both ends of the bracket already hold the `Preview` —
    /// the reload path and the `renderComplete` handler — so nothing else has
    /// to be threaded through.
    pending_scroll: Rc<Cell<Option<f64>>>,
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

        Self { web_view, pending_scroll: Rc::new(Cell::new(None)) }
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

    /// Remember the reading position, then run `then`.
    ///
    /// `window.tvmv.render` replaces `#content` outright, which drops the page
    /// to the top — so a live reload of the document the user is reading loses
    /// their place unless the position is carried across. `ViewerModel.reload`
    /// brackets its render the same way on the Mac.
    ///
    /// The value arrives from the web process on a later main-loop turn, so the
    /// caller's re-render is scheduled from `then` rather than after the call.
    /// Ordering the other way would let the DOM be replaced before the capture
    /// landed, and the ratio read back would be the new page's zero.
    pub fn capture_scroll_ratio(&self, then: impl FnOnce() + 'static) {
        let slot = Rc::clone(&self.pending_scroll);
        self.eval_json("window.tvmv.getScrollRatio()", move |value| {
            slot.set(captured_ratio(value));
            then();
        });
    }

    /// Put a captured position back, if there is one. Consumes it either way.
    ///
    /// Call on `renderComplete`: that fires after the lazy highlight, KaTeX and
    /// Mermaid passes, all of which change the document's height. Restoring
    /// before them would land against a `scrollHeight` that is about to grow.
    pub fn restore_scroll_ratio(&self) {
        if let Some(script) = restore_script(self.pending_scroll.take()) {
            self.eval(&script);
        }
    }
}

/// Decode what `getScrollRatio` returned, keeping only a position worth
/// restoring.
///
/// A page at the very top needs nothing put back — a fresh render starts there
/// — so `0` is dropped along with a missing or non-numeric reply. The clamp
/// also strips NaN and infinity, neither of which survives a trip through
/// `format!` into JS as a number.
fn captured_ratio(value: Option<serde_json::Value>) -> Option<f64> {
    let ratio = value?.as_f64()?;
    (ratio.is_finite() && ratio > 0.0).then(|| ratio.min(1.0))
}

/// The restore script, or `None` when there is nothing to restore.
///
/// **Deliberately not `requestAnimationFrame`.** `PreviewBridge` on the Mac
/// waits two frames for layout to settle, and the direct port of that does not
/// work: WebKit stops serving frames to a window it considers unviewable, so
/// the callbacks never run and the position is silently never restored.
/// `examples/reload_scroll_probe` caught it — `raf` was still `0` a full second
/// after `renderComplete`. That is not a quirk of the probe: a live reload
/// happens *because* the user is working in another application, so an
/// unfocused or occluded window is the normal case here, not the exception.
///
/// Reading `scrollHeight` instead forces a synchronous layout, which is all the
/// scroll needs. `renderComplete` already means the DOM is final, so a flushed
/// layout gives the finished height without waiting for anything to be painted.
/// `boot.js`'s `maxScroll` reads it too; the explicit read is insurance against
/// that changing.
fn restore_script(ratio: Option<f64>) -> Option<String> {
    let ratio = ratio?;
    Some(format!(
        "void document.documentElement.scrollHeight;window.tvmv.setScrollRatio({ratio});"
    ))
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

#[cfg(test)]
mod tests {
    use super::{captured_ratio, restore_script};
    use serde_json::json;

    #[test]
    fn a_real_position_round_trips() {
        assert_eq!(captured_ratio(Some(json!(0.42))), Some(0.42));
    }

    /// The top of the page is where a fresh render already lands, so there is
    /// nothing to put back and no reason to touch the page.
    #[test]
    fn the_top_of_the_page_is_not_worth_restoring() {
        assert_eq!(captured_ratio(Some(json!(0.0))), None);
        assert_eq!(restore_script(captured_ratio(Some(json!(0.0)))), None);
    }

    /// A dead web process, a page without `boot.js` yet, or a JS exception all
    /// arrive as a missing or non-numeric value. None of them should scroll.
    #[test]
    fn a_missing_or_non_numeric_reply_restores_nothing() {
        assert_eq!(captured_ratio(None), None);
        assert_eq!(captured_ratio(Some(json!(null))), None);
        assert_eq!(captured_ratio(Some(json!("0.5"))), None);
        assert_eq!(captured_ratio(Some(json!({"ratio": 0.5}))), None);
    }

    #[test]
    fn an_out_of_range_ratio_clamps() {
        assert_eq!(captured_ratio(Some(json!(1.5))), Some(1.0));
    }

    /// The ratio is interpolated into JS as a bare number, so it has to be one:
    /// `f64::INFINITY` formats as `inf`, which is an undefined identifier in JS,
    /// not a number. `captured_ratio` is the only producer, and it rejects both
    /// non-finite values.
    #[test]
    fn the_emitted_ratio_is_always_a_js_number() {
        for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert_eq!(captured_ratio(Some(json!(value))), None, "{value}");
        }
        let script = restore_script(Some(0.5)).expect("a script for a real ratio");
        assert!(script.contains("setScrollRatio(0.5)"), "{script}");
        assert!(!script.contains("inf") && !script.contains("NaN"), "{script}");
    }

    /// The restore must not depend on a frame being served. WebKit withholds
    /// frames from a window it thinks nobody is looking at, and that is exactly
    /// the window a live reload lands in — see `restore_script`.
    #[test]
    fn the_restore_never_waits_for_a_frame() {
        let script = restore_script(Some(0.25)).expect("a script for a real ratio");
        assert!(!script.contains("requestAnimationFrame"), "{script}");
        assert!(!script.contains("setTimeout"), "{script}");
        // A layout flush first, so the height the ratio is applied to is final.
        assert!(script.contains("scrollHeight"), "{script}");
        assert!(
            script.find("scrollHeight") < script.find("setScrollRatio"),
            "the flush has to come before the scroll: {script}"
        );
    }

    /// Both halves of the bracket are `boot.js` functions. The shared web layer
    /// is the contract, so a rename there has to fail here rather than at
    /// runtime, where a silent `undefined is not a function` just loses the
    /// scroll position.
    #[test]
    fn boot_js_exposes_both_scroll_helpers() {
        let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
        let boot = ["web/boot.js", "Sources/TVMVCore/Resources/web/boot.js"]
            .iter()
            .map(|c| root.join(c))
            .find(|p| p.exists())
            .and_then(|p| std::fs::read_to_string(p).ok())
            .expect("the shared boot.js");

        for name in ["getScrollRatio", "setScrollRatio"] {
            assert!(boot.contains(&format!("{name}: {name}")), "window.tvmv.{name} is gone");
        }
    }
}
