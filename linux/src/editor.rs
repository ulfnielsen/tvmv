//! The CodeMirror editor pane and its bridge.
//!
//! Mirrors `EditorBridge.swift` against WebKitGTK. As with the preview, the JS
//! side is untouched: WebKitGTK exposes the same `window.webkit.messageHandlers`
//! object, so `editor.js` posts to `tvmvEditor` exactly as it does on macOS.
//!
//! Message vocabulary: inbound `ready`, `textPatch`, `cursorMoved`, `scrolled`,
//! `error`; outbound `setText`, `scrollToLine`, `restore`, `getText`,
//! `applyStyle`, `focusEditor`.

use gtk4::gio;
use webkit6::prelude::*;
use webkit6::{UserContentManager, WebContext, WebView};

use crate::assets::SCHEME;
use crate::js;
use crate::patch::Patch;

/// What the editor page reports.
#[derive(Debug, Clone)]
pub enum EditorMessage {
    /// The page is loaded and `window.tvmvEditor` is callable.
    Ready,
    /// Settled edits, already debounced page-side. `length` is the editor's
    /// post-change document length in UTF-16 units.
    TextPatch { patches: Vec<Patch>, length: usize },
    CursorMoved { line: i64, offset: i64 },
    Scrolled { top_line: i64 },
    Error(String),
}

pub struct Editor {
    pub web_view: WebView,
}

impl Editor {
    pub fn new(on_message: impl Fn(EditorMessage) + 'static) -> Self {
        let context = WebContext::default().expect("a default WebKit context");

        let content_manager = UserContentManager::new();
        content_manager.register_script_message_handler("tvmvEditor", None);
        content_manager.connect_script_message_received(Some("tvmvEditor"), move |_, value| {
            if let Some(message) = parse_message(value) {
                on_message(message);
            }
        });

        let web_view = WebView::builder()
            .web_context(&context)
            .user_content_manager(&content_manager)
            .build();

        Self { web_view }
    }

    pub fn load(&self) {
        self.web_view.load_uri(&format!("{SCHEME}://app/editor.html"));
    }

    fn eval(&self, script: &str) {
        self.web_view.evaluate_javascript(script, None, None, gio::Cancellable::NONE, |_| {});
    }

    /// Replace the editor's document. `reset_history` drops the undo stack,
    /// which is right when opening a different document and wrong for a reload.
    pub fn set_text(&self, text: &str, reset_history: bool) {
        self.eval(&format!(
            "window.tvmvEditor.setText({}, {reset_history});",
            js::literal(text)
        ));
    }

    pub fn apply_style(&self, style_json: &str) {
        self.eval(&format!("window.tvmvEditor.applyStyle({});", js::literal(style_json)));
    }

    pub fn scroll_to_line(&self, line: i64, place_cursor: bool) {
        self.eval(&format!("window.tvmvEditor.scrollToLine({line}, {place_cursor});"));
    }

    pub fn restore(&self, cursor_offset: i64, top_line: i64) {
        self.eval(&format!("window.tvmvEditor.restore({cursor_offset}, {top_line});"));
    }

    pub fn focus(&self) {
        self.eval("window.tvmvEditor.focusEditor();");
    }

    /// Pull the whole document.
    ///
    /// The authoritative resync path: used whenever a patch payload is
    /// incoherent, and on closing the pane, because the page's blur-flush races
    /// web view teardown and a settled keystroke must never be dropped.
    pub fn get_text(&self, on_result: impl FnOnce(Option<String>) + 'static) {
        self.web_view.evaluate_javascript(
            "window.tvmvEditor.getText()",
            None,
            None,
            gio::Cancellable::NONE,
            move |result| {
                let text = result
                    .ok()
                    .and_then(|v| v.to_json(0))
                    .and_then(|json| serde_json::from_str::<String>(json.as_str()).ok());
                on_result(text);
            },
        );
    }
}

fn parse_message(value: &webkit6::javascriptcore::Value) -> Option<EditorMessage> {
    let json = value.to_json(0)?;
    let parsed: serde_json::Value = serde_json::from_str(json.as_str()).ok()?;

    match parsed.get("type")?.as_str()? {
        "ready" => Some(EditorMessage::Ready),
        "textPatch" => {
            let raw = parsed.get("patches")?.as_array()?;
            let length = parsed.get("length")?.as_i64()?;
            let patches: Vec<Patch> = raw.iter().filter_map(parse_patch).collect();
            // A triple that failed to parse means the payload is incoherent —
            // deliver an empty list so the caller resyncs rather than applying
            // a partial edit.
            let patches = if patches.len() == raw.len() { patches } else { Vec::new() };
            Some(EditorMessage::TextPatch { patches, length: length.max(0) as usize })
        }
        "cursorMoved" => Some(EditorMessage::CursorMoved {
            line: parsed.get("line")?.as_i64()?,
            offset: parsed.get("offset")?.as_i64()?,
        }),
        "scrolled" => Some(EditorMessage::Scrolled { top_line: parsed.get("topLine")?.as_i64()? }),
        "error" => Some(EditorMessage::Error(
            parsed.get("message").and_then(|m| m.as_str()).unwrap_or("Unknown error").to_string(),
        )),
        _ => None,
    }
}

/// One `[from, to, insert]` triple.
fn parse_patch(entry: &serde_json::Value) -> Option<Patch> {
    let triple = entry.as_array()?;
    if triple.len() != 3 {
        return None;
    }
    Some(Patch::new(triple[0].as_i64()?, triple[1].as_i64()?, triple[2].as_str()?))
}
