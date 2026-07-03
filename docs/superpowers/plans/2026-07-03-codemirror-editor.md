# CodeMirror 6 Editor Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the NSTextView editor pane with an embedded, vendored CodeMirror 6 source editor, moving keystrokes off the SwiftUI publish path (the typing-lag fix) while preserving every behavior of the split-editing feature.

**Architecture:** A second WKWebView hosts only CodeMirror (page: `editor.html` + `editor.js` + committed `vendor/codemirror/codemirror.bundle.js`). The bridge is event-driven: CM *pushes* debounced `textChanged`/`cursorMoved`/`scrolled` messages; native *sends* async commands (`setText`, `scrollToLine`, `restore`, `focus`, `getText`, `applyStyle`). `ViewerModel`'s dirty/save/reload state machine is untouched (its 30 tests must keep passing); its editor plumbing swaps from the synchronous `EditorController` to the async `EditorBridge` with an event-fed position cache. The close guard becomes an async flow because a correct dirty check must flush the bridge first. Spec: `docs/superpowers/specs/2026-07-03-codemirror-editor-design.md`.

**Tech Stack:** Swift 6 / SwiftPM, SwiftUI + AppKit, WKWebView ×2, CodeMirror 6 (rollup IIFE bundle), XCTest.

## Global Constraints

- **Every `swift` command needs the Xcode toolchain:** `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (plain `swift test` fails: `no such module 'XCTest'`).
- **The 30 existing tests must keep passing unmodified** — `ViewerModelEditingTests` constructs the model headless and exercises `textEdited`/`save`/`reload(force:)`/`discardAndReload`; the state machine API must not change. Zero warnings.
- **QuickLook untouched:** no changes to `MarkdownRenderer.swift`, `MarkdownText.swift`, or `quicklook/`.
- **Vendored & offline:** the CM bundle is COMMITTED under `Sources/tvmv/Resources/web/vendor/codemirror/`; npm/rollup are needed only to (re)build it. Verified working versions (from a real build on this machine, Node v26): `codemirror@6.0.2`, `@codemirror/lang-markdown@6.5.0`, `@codemirror/language-data@6.5.2`, `rollup@4.62.2`, `@rollup/plugin-node-resolve@16.0.3`, `@rollup/plugin-terser@1.0.0`, plus `@codemirror/theme-one-dark@6` (pin whatever the build resolves). The rollup invocation REQUIRES `--inlineDynamicImports` (language-data uses dynamic import; IIFE cannot code-split). Expected bundle size ≈ 1.5–1.7 MB minified.
- **Editor feel (user-approved default):** soft wrap ON, NO line-number gutter, Markdown highlighting with fenced-code languages, active-line highlight.
- **Find (⌘F) stays preview-only.** No CM search panel.
- Message handler name for the editor webview is `tvmvEditor` (the preview keeps `tvmv`).
- Commit after each task with trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: CodeMirror bundle build script + committed bundle

**Files:**
- Create: `build/editor-bundle.fish`
- Create (generated + committed): `Sources/tvmv/Resources/web/vendor/codemirror/codemirror.bundle.js`

**Interfaces:**
- Consumes: nothing.
- Produces: a committed IIFE bundle that sets `window.CM` with keys: `EditorView, EditorState, Compartment, keymap, drawSelection, highlightActiveLine, defaultKeymap, history, historyKeymap, undo, redo, markdown, languages, syntaxHighlighting, defaultHighlightStyle, oneDark`.

- [ ] **Step 1: Write the build script** — create `build/editor-bundle.fish`:

```fish
#!/usr/bin/env fish
#
# editor-bundle.fish — build the vendored CodeMirror 6 bundle for the editor
# pane. The output is COMMITTED (Sources/tvmv/Resources/web/vendor/codemirror/
# codemirror.bundle.js) so normal builds never need npm; run this only to
# upgrade CodeMirror.
#
# Requires: node + npm (verified with Node v26).
#
# Note: --inlineDynamicImports is required — @codemirror/language-data lazy-
# loads languages via dynamic import(), which IIFE output cannot code-split.

set -l script_dir (cd (dirname (status --current-filename)); pwd)
set -l repo_root (dirname $script_dir)
set -l out_dir "$repo_root/Sources/tvmv/Resources/web/vendor/codemirror"
set -l work (mktemp -d)

echo "==> building CodeMirror bundle in $work"
cd $work; or exit 1

npm init -y >/dev/null 2>&1

# Pinned versions — verified building cleanly together on 2026-07-03.
npm install --no-audit --no-fund --silent \
    codemirror@6.0.2 \
    @codemirror/lang-markdown@6.5.0 \
    @codemirror/language-data@6.5.2 \
    @codemirror/theme-one-dark@6 \
    rollup@4.62.2 \
    @rollup/plugin-node-resolve@16.0.3 \
    @rollup/plugin-terser@1.0.0
or begin; echo "npm install failed" >&2; exit 1; end

printf '%s\n' '
// tvmv editor bundle entry: expose the CodeMirror 6 pieces editor.js needs
// on window.CM, as a single vendored IIFE.
import { EditorView, keymap, drawSelection, highlightActiveLine } from "@codemirror/view";
import { EditorState, Compartment } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap, undo, redo } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { languages } from "@codemirror/language-data";
import { syntaxHighlighting, defaultHighlightStyle } from "@codemirror/language";
import { oneDark } from "@codemirror/theme-one-dark";

window.CM = {
  EditorView, EditorState, Compartment, keymap, drawSelection, highlightActiveLine,
  defaultKeymap, history, historyKeymap, undo, redo,
  markdown, languages, syntaxHighlighting, defaultHighlightStyle, oneDark,
};' > entry.js

npx rollup entry.js --format iife --inlineDynamicImports \
    --plugin @rollup/plugin-node-resolve --plugin @rollup/plugin-terser \
    --file codemirror.bundle.js
or begin; echo "rollup failed" >&2; exit 1; end

# Smoke test: the bundle must define window.CM with the expected surface.
node -e '
global.window = {};
require("./codemirror.bundle.js");
const need = ["EditorView","EditorState","Compartment","keymap","drawSelection",
  "highlightActiveLine","defaultKeymap","history","historyKeymap","undo","redo",
  "markdown","languages","syntaxHighlighting","defaultHighlightStyle","oneDark"];
const missing = need.filter(k => !(k in global.window.CM));
if (missing.length) { console.error("missing:", missing.join(",")); process.exit(1); }
console.log("window.CM ok:", need.length, "exports");'
or begin; echo "bundle smoke test failed" >&2; exit 1; end

mkdir -p $out_dir
cp codemirror.bundle.js $out_dir/
echo "==> wrote $out_dir/codemirror.bundle.js ("(du -h $out_dir/codemirror.bundle.js | cut -f1)")"
echo "==> resolved versions:"
node -e 'const l=require("./package-lock.json");
for (const n of ["codemirror","@codemirror/lang-markdown","@codemirror/language-data","@codemirror/theme-one-dark"])
  console.log("   ", n, l.packages["node_modules/"+n].version)'
rm -rf $work
```

- [ ] **Step 2: Run it**

Run: `fish build/editor-bundle.fish`
Expected: `window.CM ok: 16 exports`, then `==> wrote .../vendor/codemirror/codemirror.bundle.js (~1.5M)` and the resolved versions. (The base combination minus one-dark was verified on this machine on 2026-07-03; if `@codemirror/theme-one-dark@6` introduces a resolution conflict, report BLOCKED with the npm error rather than changing other pins.)

- [ ] **Step 3: Verify the app still builds and tests pass** (nothing links the bundle yet, but the resource dir changed)

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: build succeeds; 30/30 tests pass.

- [ ] **Step 4: Commit**

```bash
git add build/editor-bundle.fish Sources/tvmv/Resources/web/vendor/codemirror/codemirror.bundle.js
git commit -m "Vendor CodeMirror 6 bundle + build script for the editor pane"
```

---

### Task 2: Editor page — editor.html, editor.css, editor.js

**Files:**
- Create: `Sources/tvmv/Resources/web/editor.html`
- Create: `Sources/tvmv/Resources/web/editor.css`
- Create: `Sources/tvmv/Resources/web/editor.js`

**Interfaces:**
- Consumes: `window.CM` from Task 1's bundle; the page is loaded from `tvmv-asset://app/editor.html` (the existing `AssetSchemeHandler` serves everything under the web resources dir; `template.html` already loads this way).
- Produces `window.tvmvEditor` with:
  - `setText(text, resetHistory)` — full replacement; `resetHistory: true` rebuilds the EditorState so ⌘Z can't resurrect replaced text; selection is clamped.
  - `scrollToLine(line, placeCursor)` — 1-based, clamped; scrolls the line near the top; optionally moves the cursor to its start.
  - `restore(cursorOffset, topLine)` — clamped cursor offset + top line.
  - `getText()` — returns the full document string.
  - `applyStyle(json)` — `{monoFont, baseSize, theme}` (`theme` is `"light"`/`"dark"`).
  - `focusEditor()`.
- Posts to `window.webkit.messageHandlers.tvmvEditor`:
  - `{type:"ready"}` once the view exists.
  - `{type:"textChanged", text}` — debounced 100 ms, flushed immediately on blur.
  - `{type:"cursorMoved", line, offset}` — debounced 100 ms (1-based line, UTF-16 char offset).
  - `{type:"scrolled", topLine}` — debounced 100 ms (1-based first visible line).

No JS test infra (existing constraint); verified by `swift build` here, exercised in Task 6's manual pass. Keep every function small and ES2017-compatible (this page is only ever loaded in WKWebView).

- [ ] **Step 1: Create `Sources/tvmv/Resources/web/editor.html`:**

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <link rel="stylesheet" href="editor.css">
  <script src="vendor/codemirror/codemirror.bundle.js"></script>
</head>
<body>
  <div id="editor"></div>
  <script src="editor.js"></script>
</body>
</html>
```

- [ ] **Step 2: Create `Sources/tvmv/Resources/web/editor.css`:**

```css
/* tvmv editor page — chrome around CodeMirror. Theme + typography arrive via
   applyStyle() as CSS custom properties / data-theme, mirroring app.css. */

:root {
  --tvmv-editor-mono: Menlo, monospace;
  --tvmv-editor-size: 13px;
}

html, body { height: 100%; margin: 0; }
#editor { height: 100%; }

.cm-editor { height: 100%; font-size: var(--tvmv-editor-size); }
.cm-editor .cm-content, .cm-editor .cm-gutters {
  font-family: var(--tvmv-editor-mono);
}
.cm-editor .cm-content { padding: 12px 0; }
.cm-editor .cm-line { padding: 0 12px; }
.cm-editor.cm-focused { outline: none; }
```

- [ ] **Step 3: Create `Sources/tvmv/Resources/web/editor.js`:**

```js
/*
 * editor.js — tvmv CodeMirror 6 editor pane controller.
 *
 * Event-driven bridge: keystrokes stay inside CodeMirror; the page pushes
 * debounced textChanged / cursorMoved / scrolled messages to native, and
 * native sends commands via window.tvmvEditor. See the design spec
 * (2026-07-03-codemirror-editor-design.md) for the contract.
 */
(function () {
  "use strict";

  var CMSTATE = window.CM;

  function post(msg) {
    try { window.webkit.messageHandlers.tvmvEditor.postMessage(msg); } catch (e) {}
  }

  /* ---- debounced event reporting ---------------------------------------- */

  var TEXT_DEBOUNCE_MS = 100;
  var POS_DEBOUNCE_MS = 100;
  var textTimer = null, cursorTimer = null, scrollTimer = null;

  function flushText() {
    if (textTimer !== null) { clearTimeout(textTimer); textTimer = null; }
    post({ type: "textChanged", text: view.state.doc.toString() });
  }

  function queueText() {
    if (textTimer !== null) clearTimeout(textTimer);
    textTimer = setTimeout(flushText, TEXT_DEBOUNCE_MS);
  }

  function queueCursor() {
    if (cursorTimer !== null) clearTimeout(cursorTimer);
    cursorTimer = setTimeout(function () {
      cursorTimer = null;
      var head = view.state.selection.main.head;
      var line = view.state.doc.lineAt(head).number;
      post({ type: "cursorMoved", line: line, offset: head });
    }, POS_DEBOUNCE_MS);
  }

  function queueScroll() {
    if (scrollTimer !== null) clearTimeout(scrollTimer);
    scrollTimer = setTimeout(function () {
      scrollTimer = null;
      var block = view.lineBlockAtHeight(view.scrollDOM.scrollTop);
      var line = view.state.doc.lineAt(block.from).number;
      post({ type: "scrolled", topLine: line });
    }, POS_DEBOUNCE_MS);
  }

  /* ---- editor construction ---------------------------------------------- */

  var themeCompartment = new CMSTATE.Compartment();

  function extensions() {
    return [
      CMSTATE.history(),
      CMSTATE.drawSelection(),
      CMSTATE.highlightActiveLine(),
      CMSTATE.EditorView.lineWrapping,               // prose style: soft wrap
      CMSTATE.markdown({ codeLanguages: CMSTATE.languages }),
      CMSTATE.syntaxHighlighting(CMSTATE.defaultHighlightStyle, { fallback: true }),
      CMSTATE.keymap.of(CMSTATE.defaultKeymap.concat(CMSTATE.historyKeymap)),
      themeCompartment.of([]),                       // light: bare; dark: oneDark
      CMSTATE.EditorView.updateListener.of(function (update) {
        if (update.docChanged) { queueText(); queueCursor(); }
        else if (update.selectionSet) { queueCursor(); }
      }),
    ];
  }

  var view = new CMSTATE.EditorView({
    state: CMSTATE.EditorState.create({ doc: "", extensions: extensions() }),
    parent: document.getElementById("editor"),
  });

  view.scrollDOM.addEventListener("scroll", queueScroll);
  // Flush pending keystrokes the moment focus leaves the editor, so native
  // state is authoritative before any click/menu action can act on it.
  view.contentDOM.addEventListener("blur", flushText);

  /* ---- native command surface ------------------------------------------- */

  function clampOffset(offset) {
    return Math.max(0, Math.min(Number(offset) || 0, view.state.doc.length));
  }

  function clampLine(line) {
    return Math.max(1, Math.min(Number(line) || 1, view.state.doc.lines));
  }

  function setText(text, resetHistory) {
    if (resetHistory) {
      // Fresh state: replaced text (external reload / discard) must not be
      // resurrectable via undo.
      view.setState(CMSTATE.EditorState.create({ doc: text, extensions: extensions() }));
      applyStyle(_lastStyle); // recreate loses the theme compartment's config
    } else {
      var sel = clampOffset(view.state.selection.main.head);
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: text },
        selection: { anchor: Math.min(sel, text.length) },
      });
    }
  }

  function scrollToLine(line, placeCursor) {
    var pos = view.state.doc.line(clampLine(line)).from;
    var spec = { effects: CMSTATE.EditorView.scrollIntoView(pos, { y: "start", yMargin: 8 }) };
    if (placeCursor) spec.selection = { anchor: pos };
    view.dispatch(spec);
  }

  function restore(cursorOffset, topLine) {
    view.dispatch({ selection: { anchor: clampOffset(cursorOffset) } });
    var pos = view.state.doc.line(clampLine(topLine)).from;
    view.dispatch({ effects: CMSTATE.EditorView.scrollIntoView(pos, { y: "start", yMargin: 8 }) });
  }

  function getText() {
    return view.state.doc.toString();
  }

  var _lastStyle = null;

  function applyStyle(json) {
    if (json == null) return;
    var cfg = (typeof json === "string") ? JSON.parse(json) : json;
    _lastStyle = cfg;
    var rootStyle = document.documentElement.style;
    if (cfg.monoFont != null) {
      rootStyle.setProperty("--tvmv-editor-mono", JSON.stringify(cfg.monoFont) + ", monospace");
    }
    if (cfg.baseSize != null) {
      rootStyle.setProperty("--tvmv-editor-size", cfg.baseSize + "px");
    }
    if (cfg.theme === "dark" || cfg.theme === "light") {
      view.dispatch({
        effects: themeCompartment.reconfigure(cfg.theme === "dark" ? CMSTATE.oneDark : []),
      });
    }
  }

  function focusEditor() {
    view.focus();
  }

  window.tvmvEditor = {
    setText: setText,
    scrollToLine: scrollToLine,
    restore: restore,
    getText: getText,
    applyStyle: applyStyle,
    focusEditor: focusEditor,
  };

  post({ type: "ready" });
})();
```

- [ ] **Step 4: Build (resources compile into the bundle; no Swift changes yet)**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: build succeeds; 30/30.

- [ ] **Step 5: Commit**

```bash
git add Sources/tvmv/Resources/web/editor.html Sources/tvmv/Resources/web/editor.css Sources/tvmv/Resources/web/editor.js
git commit -m "Editor page: CodeMirror host with event-driven tvmvEditor bridge"
```

---

### Task 3: JSString helper + CodeMirrorEditorPane + EditorBridge

**Files:**
- Create: `Sources/tvmv/JSString.swift`
- Create: `Sources/tvmv/CodeMirrorEditorPane.swift`
- Modify: `Sources/tvmv/MarkdownWebView.swift` (replace its private `jsString` with the shared helper)

**Interfaces:**
- Consumes: the `tvmvEditor` page contract (Task 2); `AssetSchemeHandler(appBaseDir:docBaseDir:)` (existing).
- Produces:
  - `enum JSString { static func literal(_ value: String) -> String }` — JSON-encodes a Swift string as a safe JS string literal.
  - `struct EditorPosition { var cursorOffset: Int; var topLine: Int }` (moves here; the NSTextView pane that defined it is deleted in Task 4).
  - `struct EditorBridgeCallbacks { var onReady: (() -> Void)?; var onTextChanged: ((String) -> Void)?; var onCursorMoved: ((Int, Int) -> Void)?; var onScrolled: ((Int) -> Void)? }` (all `@MainActor` closures).
  - `@MainActor final class EditorBridge` with: `func setText(_ text: String, resetHistory: Bool) async`, `func scrollToLine(_ line: Int, placeCursor: Bool) async`, `func restore(_ p: EditorPosition) async`, `func getText() async -> String?`, `func applyStyle(json: String) async`, `func focus()`.
  - `struct CodeMirrorEditorPane: NSViewRepresentable` with init parameters `appWebDir: URL`, `callbacks: EditorBridgeCallbacks`, `onMakeBridge: (EditorBridge) -> Void`.

- [ ] **Step 1: Create `Sources/tvmv/JSString.swift`:**

```swift
import Foundation

/// JSON-encode a Swift string into a safe JS string literal, for building
/// `evaluateJavaScript` calls. Shared by the preview and editor bridges.
enum JSString {
    static func literal(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\"\""
    }
}
```

- [ ] **Step 2: Point `MarkdownWebController` at it** — in `Sources/tvmv/MarkdownWebView.swift`, delete the private `jsString` helper at the bottom of `MarkdownWebController`:

```swift
    /// JSON-encode a Swift string into a safe JS string literal.
    private static func jsString(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\"\""
    }
```

and replace every `Self.jsString(` in that file with `JSString.literal(` (there are five: `setContent` ×2, `applyStyle`, `setUserCSS`, `scrollToAnchor`, `find`).

- [ ] **Step 3: Create `Sources/tvmv/CodeMirrorEditorPane.swift`:**

```swift
import SwiftUI
import AppKit
import WebKit

/// A captured editor location, used to restore cursor + scroll when the
/// editor pane is closed and reopened. Offsets are UTF-16 code units (both
/// CodeMirror positions and Swift's NSString-view lengths count UTF-16).
struct EditorPosition {
    var cursorOffset: Int   // clamped on restore
    var topLine: Int        // 1-based
}

/// Events pushed by the editor page. All delivered on the main actor.
struct EditorBridgeCallbacks {
    var onReady: (@MainActor () -> Void)?
    var onTextChanged: (@MainActor (String) -> Void)?
    /// (1-based line, UTF-16 offset)
    var onCursorMoved: (@MainActor (Int, Int) -> Void)?
    /// 1-based first visible line
    var onScrolled: (@MainActor (Int) -> Void)?
    /// Editor page failed to load (spec: surface via the existing
    /// errorMessage path; typing into a dead pane visibly does nothing).
    var onError: (@MainActor (String) -> Void)?
}

/// Command surface into the CodeMirror page, mirroring MarkdownWebController's
/// role for the preview. All calls are async JS round-trips; they no-op until
/// the page is loaded (evaluate failures return nil).
@MainActor
final class EditorBridge {
    weak var webView: WKWebView?

    func setText(_ text: String, resetHistory: Bool) async {
        await run("window.tvmvEditor.setText(\(JSString.literal(text)), \(resetHistory));")
    }

    func scrollToLine(_ line: Int, placeCursor: Bool) async {
        await run("window.tvmvEditor.scrollToLine(\(line), \(placeCursor));")
    }

    func restore(_ p: EditorPosition) async {
        await run("window.tvmvEditor.restore(\(p.cursorOffset), \(p.topLine));")
    }

    /// The authoritative document, for save flushes. Nil when the page is gone.
    func getText() async -> String? {
        await evaluate("window.tvmvEditor.getText()") as? String
    }

    func applyStyle(json: String) async {
        await run("window.tvmvEditor.applyStyle(\(JSString.literal(json)));")
    }

    /// Keyboard focus: the web view first, then CodeMirror inside it.
    func focus() {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
        Task { await run("window.tvmvEditor.focusEditor();") }
    }

    @discardableResult
    private func evaluate(_ js: String) async -> Any? {
        guard let webView else { return nil }
        do {
            return try await webView.evaluateJavaScript(js, in: nil, contentWorld: .page)
        } catch {
            return nil
        }
    }

    private func run(_ js: String) async {
        _ = await evaluate(js)
    }
}

/// NSViewRepresentable wrapping the editor WKWebView (a second, dedicated
/// web view — the preview's pipeline is untouched).
struct CodeMirrorEditorPane: NSViewRepresentable {
    /// Base directory of bundled web resources (the `web/` folder).
    let appWebDir: URL
    var callbacks: EditorBridgeCallbacks = .init()
    var onMakeBridge: (@MainActor (EditorBridge) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(callbacks: callbacks) }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()

        let handler = AssetSchemeHandler(appBaseDir: appWebDir, docBaseDir: nil)
        configuration.setURLSchemeHandler(handler, forURLScheme: AssetSchemeHandler.scheme)
        configuration.userContentController.add(coordinator, name: "tvmvEditor")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        let bridge = EditorBridge()
        bridge.webView = webView
        coordinator.bridge = bridge
        onMakeBridge?(bridge)

        if let url = URL(string: "\(AssetSchemeHandler.scheme)://app/editor.html") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.callbacks = callbacks
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var callbacks: EditorBridgeCallbacks
        weak var webView: WKWebView?
        var bridge: EditorBridge?

        init(callbacks: EditorBridgeCallbacks) {
            self.callbacks = callbacks
        }

        // MARK: WKNavigationDelegate — editor page load failures

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            callbacks.onError?("Editor failed to load: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            callbacks.onError?("Editor failed to load: \(error.localizedDescription)")
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // WKScriptMessage delivery is main-thread; hop explicitly for Swift 6.
            MainActor.assumeIsolated {
                guard message.name == "tvmvEditor",
                      let dict = message.body as? [String: Any],
                      let type = dict["type"] as? String
                else { return }

                switch type {
                case "ready":
                    callbacks.onReady?()
                case "textChanged":
                    if let text = dict["text"] as? String {
                        callbacks.onTextChanged?(text)
                    }
                case "cursorMoved":
                    if let line = dict["line"] as? Int, let offset = dict["offset"] as? Int {
                        callbacks.onCursorMoved?(line, offset)
                    }
                case "scrolled":
                    if let line = dict["topLine"] as? Int {
                        callbacks.onScrolled?(line)
                    }
                default:
                    break
                }
            }
        }
    }
}
```

(Concurrency note: if the compiler rejects `nonisolated func userContentController` + `MainActor.assumeIsolated`, match however `MarkdownWebView.Coordinator` declares the same delegate method in this codebase and mirror it exactly — behavior identical, report the adjustment.)

- [ ] **Step 4: Build + full suite**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: FAILS — `EditorPosition` is now declared twice (here and in `EditorPane.swift`). That's expected mid-flight: delete the `EditorPosition` struct from `Sources/tvmv/EditorPane.swift` (only the struct — the rest of that file survives until Task 4), then re-run.
Expected after that: build succeeds; 30/30.

- [ ] **Step 5: Commit**

```bash
git add Sources/tvmv/JSString.swift Sources/tvmv/CodeMirrorEditorPane.swift Sources/tvmv/MarkdownWebView.swift Sources/tvmv/EditorPane.swift
git commit -m "Add EditorBridge + CodeMirrorEditorPane; share the JS string helper"
```

---

### Task 4: Swap the pane — ViewerModel rewiring, ViewerWindow, deletions

This is one task because it is one compile-coherent change: the model's editor
plumbing, the window's pane construction, and the deletion of the NSTextView
implementation must land together.

**Files:**
- Modify: `Sources/tvmv/ViewerModel.swift` (editor plumbing only — the dirty/save/reload state machine is untouched)
- Modify: `Sources/tvmv/ViewerWindow.swift` (editorPane view + style onChange)
- Modify: `Sources/tvmv/AppSettings.swift` (add `editorStyleJSON`)
- Delete: `Sources/tvmv/EditorPane.swift`, `Sources/tvmv/LineIndex.swift`, `Tests/tvmvTests/LineIndexTests.swift`
- Test: `Tests/tvmvTests/ViewerModelEditingTests.swift` (append one test; existing 30 — minus the 3 LineIndex tests — must pass unmodified)

**Interfaces:**
- Consumes: `EditorBridge`, `EditorBridgeCallbacks`, `EditorPosition`, `CodeMirrorEditorPane` (Task 3).
- Produces (ViewerModel):
  - `func attach(editor: EditorBridge)` (replaces the `EditorController` overload)
  - `func editorReady()` — seeds text/position/style/focus; called from the `ready` event
  - `func editorTextChanged(_ text: String)` — event entry; forwards to the unchanged `textEdited(_:)`
  - `func editorCursorMoved(line: Int, offset: Int)` / `func editorScrolled(topLine: Int)` — replace the parameterless versions; update the position cache and debounce preview sync as before
  - `func flushAndSave() async` — pulls authoritative text from the bridge (falls back to cached `text` when the bridge is gone), then `save()`. ⌘S and the close flow use this.
- Verifies (spec requirement): typing no longer publishes `model.text` per keystroke — the editor posts at a 100 ms debounce, so SwiftUI body churn is bounded by that cadence.

- [ ] **Step 1: Write the failing test** — append to `Tests/tvmvTests/ViewerModelEditingTests.swift`:

```swift
    func testFlushAndSaveWithoutBridgeSavesCachedText() async throws {
        // The editor bridge is gone (pane closed / page dead): flushAndSave
        // must still write the model's cached text rather than losing the save.
        let url = try tempFile("# hello\n")
        let model = ViewerModel(text: "# hello\n", fileURL: url, encoding: .utf8)
        model.textEdited("# hello world\n")
        await model.flushAndSave()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# hello world\n")
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ViewerModelEditingTests`
Expected: compile FAILURE — `no member 'flushAndSave'`.

- [ ] **Step 3: Rewire `Sources/tvmv/ViewerModel.swift`.** Replace the private editor-plumbing properties:

```swift
    private var editorController: EditorController?
```

with:

```swift
    private var editorBridge: EditorBridge?
    /// Latest cursor/scroll reported by the editor's events; makes position
    /// capture on ⌘E-off synchronous even though the editor is async.
    private var lastEditorPosition = EditorPosition(cursorOffset: 0, topLine: 1)
```

3a. Replace `attach(editor:)`, `editorClosed()`, and `positionEditorOnOpen()` with:

```swift
    func attach(editor: EditorBridge) {
        editorBridge = editor
        // Positioning waits for the page's `ready` event (editorReady()).
    }

    /// The editor page is live: seed it with the document, style, and the
    /// restore-vs-reanchor position, then hand it focus.
    func editorReady() {
        Task { [weak self] in
            guard let self else { return }
            await self.editorCloseSync?.value
            guard let bridge = self.editorBridge else { return }
            await bridge.setText(self.text, resetHistory: true)
            await bridge.applyStyle(json: AppSettings.shared.editorStyleJSON)
            let previewLine = await self.controller?.topVisibleSourceLine()
            if let saved = self.savedEditorPosition,
               previewLine == self.previewTopLineAtEditorClose {
                await bridge.restore(saved)
                self.lastEditorPosition = saved
            } else {
                let line = previewLine ?? 1
                await bridge.scrollToLine(line, placeCursor: true)
                self.lastEditorPosition = EditorPosition(cursorOffset: 0, topLine: line)
            }
            bridge.focus()
        }
    }

    /// The editor pane is closing (⌘E off): remember where it was, and where
    /// the preview was, so re-entry can decide between restore and re-anchor.
    func editorClosed() {
        savedEditorPosition = lastEditorPosition
        editorBridge = nil
        renderDebounce?.cancel()
        editorCloseSync = Task { [weak self] in
            guard let self else { return }
            if self.previewNeedsRender {
                // Flush the last edit's render before recording the preview
                // position, preserving scroll so leaving edit mode never jumps.
                let ratio = await self.controller?.getScrollRatio() ?? 0
                await self.renderCurrent()
                try? await Task.sleep(nanoseconds: 60_000_000) // let layout settle
                await self.controller?.setScrollRatio(ratio)
                self.previewNeedsRender = false
            }
            self.previewTopLineAtEditorClose = await self.controller?.topVisibleSourceLine()
        }
        controller?.focus()
    }
```

3b. Replace `renderAfterEdit()`'s tail (the editor re-anchor) — the whole method becomes:

```swift
    private func renderAfterEdit() async {
        previewNeedsRender = false
        await renderCurrent()
        try? await Task.sleep(nanoseconds: 60_000_000) // let layout settle
        if isEditing {
            await controller?.scrollToSourceLine(lastEditorPosition.topLine)
        }
    }
```

3c. Replace `editorScrolled()` and `editorCursorMoved()` with event-fed versions (same debounce shape):

```swift
    /// Editor event: text changed (already debounced ~100 ms page-side).
    func editorTextChanged(_ newText: String) {
        textEdited(newText)
    }

    /// Editor event: scrolled. Keep the preview's top aligned (debounced).
    func editorScrolled(topLine: Int) {
        lastEditorPosition.topLine = topLine
        guard isEditing else { return }
        scrollSyncDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.controller?.scrollToSourceLine(topLine) }
        }
        scrollSyncDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Editor event: cursor moved. Reveal its block in the preview only if
    /// offscreen (debounced).
    func editorCursorMoved(line: Int, offset: Int) {
        lastEditorPosition.cursorOffset = offset
        guard isEditing else { return }
        cursorSyncDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.controller?.revealSourceLine(line) }
        }
        cursorSyncDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
```

3d. Replace `previewClicked(line:)`'s body:

```swift
    /// Preview click: jump the editor to the clicked block's source line and
    /// hand it focus. No-op while the editor pane is closed, so plain viewing
    /// keeps its normal click behavior (selection, links).
    func previewClicked(line: Int) {
        guard isEditing, let bridge = editorBridge else { return }
        Task {
            await bridge.scrollToLine(line, placeCursor: true)
            bridge.focus()
        }
    }
```

3e. Add the flush pair after `save()` (two methods: the close flow must be able
to flush WITHOUT saving, or "Don't Save" would save anyway):

```swift
    /// Pull the authoritative document from the editor into the model without
    /// saving (covers keystrokes inside the page's 100 ms debounce window).
    /// Falls back silently when the bridge is gone — the cached text is then
    /// at worst <100 ms stale, in a scenario where the editor process died.
    func flushEditorText() async {
        if let bridge = editorBridge, let current = await bridge.getText() {
            textEdited(current)
        }
    }

    /// Flush, then save. ⌘S and the close flow's Save button use this.
    func flushAndSave() async {
        await flushEditorText()
        save()
    }
```

3f. In `reload(force:)`, after the clean-path adoption (`text = decoded; lastSavedText = decoded`), add the editor push before the `guard isReady` line:

```swift
        if isEditing, let bridge = editorBridge {
            // Programmatic replacement: fresh history so ⌘Z can't resurrect
            // the pre-reload text. The resulting textChanged echo is a no-op
            // (textEdited guards newText != text).
            await bridge.setText(decoded, resetHistory: true)
        }
```

3g. In `applyStyle()`, forward to the editor too — the whole method becomes:

```swift
    func applyStyle() async {
        guard isReady else { return }
        await controller?.applyStyle(json: AppSettings.shared.styleJSON)
        await editorBridge?.applyStyle(json: AppSettings.shared.editorStyleJSON)
    }
```

- [ ] **Step 4: Add `editorStyleJSON` to `Sources/tvmv/AppSettings.swift`** — after `styleJSON`:

```swift
    /// JSON payload for editor.js `applyStyle` — the editor pane needs only
    /// the mono font, size, and resolved theme.
    var editorStyleJSON: String {
        let dict: [String: Any] = [
            "monoFont": monoFont, "baseSize": baseSize, "theme": resolvedTheme
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
```

- [ ] **Step 5: Rewire `Sources/tvmv/ViewerWindow.swift`** — replace the `editorPane` computed view with:

```swift
    private var editorPane: some View {
        CodeMirrorEditorPane(
            appWebDir: WebResources.baseURL,
            callbacks: EditorBridgeCallbacks(
                onReady: { model.editorReady() },
                onTextChanged: { model.editorTextChanged($0) },
                onCursorMoved: { line, offset in model.editorCursorMoved(line: line, offset: offset) },
                onScrolled: { line in model.editorScrolled(topLine: line) },
                onError: { msg in model.errorMessage = msg }
            ),
            onMakeBridge: { model.attach(editor: $0) }
        )
    }
```

- [ ] **Step 6: Delete the NSTextView implementation**

```bash
git rm Sources/tvmv/EditorPane.swift Sources/tvmv/LineIndex.swift Tests/tvmvTests/LineIndexTests.swift
```

Then grep to confirm nothing references the deleted symbols:
Run: `grep -rn "LineIndex\|EditorController\|EditorPane\b" Sources/ Tests/`
Expected: no hits (only `CodeMirrorEditorPane` matches remain if the regex catches them — that's fine).

- [ ] **Step 7: Run the new test, then the full suite**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS — 28 tests (30 − 3 LineIndex + 1 new), zero warnings, and every pre-existing `ViewerModelEditingTests` case unmodified.

- [ ] **Step 8: Commit**

```bash
git add -A Sources Tests
git commit -m "Swap the editor pane to CodeMirror: event-driven bridge, flush-save, NSTextView removed"
```

---

### Task 5: ⌘S flush path + async close flow

**Files:**
- Modify: `Sources/tvmv/ViewerWindow.swift` (save closure + guard wiring)
- Modify: `Sources/tvmv/WindowCloseGuard.swift` (async close flow)

**Interfaces:**
- Consumes: `model.flushAndSave()` (Task 4), `model.isDirty`, `model.isEditing`, `model.save()`.
- Produces: `WindowCloseGuard(needsFlow: () -> Bool, flush: () async -> Void, isDirty: () -> Bool, save: () -> Bool)` — `needsFlow` gates the async path (`isDirty || isEditing`: an open editor may hold unflushed keystrokes even when the model looks clean); clean windows keep the old synchronous fast path.
- Quit behavior (spec contingency, explicit): `AppDelegate.applicationShouldTerminate` is UNCHANGED. With the async flow, a dirty window's `windowShouldClose` starts the flow and returns false, so ⌘Q with unsaved edits cancels termination while the prompt appears; the user resolves it and quits again. Manual item verifies this exact sequence.

- [ ] **Step 1: Rework `Sources/tvmv/WindowCloseGuard.swift`** — replace the whole file with:

```swift
import SwiftUI
import AppKit

/// Attaches a Save/Don't Save/Cancel prompt to the hosting window's close
/// button when there are unsaved edits, and mirrors the dirty state into the
/// titlebar dot (`isDocumentEdited`).
///
/// SwiftUI owns the window's delegate, so we install a proxy that intercepts
/// only `windowShouldClose` and forwards everything else to the original.
///
/// The dirty path is ASYNC: a correct dirty check must first flush the
/// CodeMirror bridge (keystrokes inside its 100 ms debounce window), which
/// cannot happen synchronously inside windowShouldClose. So the delegate
/// defers the close (returns false), flushes, prompts if still dirty, then
/// re-closes with an approval flag. Clean, non-editing windows keep the old
/// synchronous fast path.
struct WindowCloseGuard: NSViewRepresentable {
    /// True when the async flow is needed (dirty, or the editor pane is open
    /// and may hold unflushed keystrokes).
    var needsFlow: () -> Bool
    /// Pull authoritative text from the editor into the model.
    var flush: () async -> Void
    /// Read live from the model after the flush.
    var isDirty: () -> Bool
    /// Attempt to save; return true when the window may close.
    var save: () -> Bool

    func makeCoordinator() -> CloseGuardDelegate { CloseGuardDelegate() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let proxy = context.coordinator
        proxy.needsFlow = needsFlow
        proxy.flush = flush
        proxy.isDirty = isDirty
        proxy.save = save
        let dirty = isDirty()
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.delegate !== proxy {
                proxy.original = window.delegate
                window.delegate = proxy
            }
            window.isDocumentEdited = dirty
        }
    }
}

/// Proxy window delegate: intercepts `windowShouldClose`, forwards the rest.
@MainActor
final class CloseGuardDelegate: NSObject, NSWindowDelegate {
    /// Held strongly: NSWindow.delegate is weak, and once we replace it we may
    /// be the only thing keeping SwiftUI's delegate alive.
    ///
    /// `nonisolated(unsafe)`: `responds(to:)` and `forwardingTarget(for:)`
    /// override NSObject's nonisolated methods, so they can't inherit this
    /// class's @MainActor isolation. AppKit always invokes window-delegate
    /// forwarding on the main thread, so this is safe in practice.
    nonisolated(unsafe) var original: NSWindowDelegate?
    var needsFlow: () -> Bool = { false }
    var flush: () async -> Void = {}
    var isDirty: () -> Bool = { false }
    var save: () -> Bool = { true }
    /// Set by the async flow just before it re-triggers the close; consumed
    /// (and reset) by the next windowShouldClose so the close proceeds.
    private var closeApproved = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeApproved {
            closeApproved = false
            return original?.windowShouldClose?(sender) ?? true
        }
        guard needsFlow() else {
            return original?.windowShouldClose?(sender) ?? true
        }
        Task { @MainActor [weak self, weak sender] in
            guard let self, let window = sender else { return }
            await self.flush()
            guard self.isDirty() else {
                self.approveAndClose(window)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes made to “\(window.title)”?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn:            // Save
                if self.save() { self.approveAndClose(window) }
                // Save failed: stay open; the model's saveError alert explains.
            case .alertThirdButtonReturn:            // Don't Save
                self.approveAndClose(window)
            default:                                 // Cancel
                break
            }
        }
        return false
    }

    /// Re-run the close with approval set; performClose (not close()) so the
    /// original SwiftUI delegate is still consulted on the approved pass.
    private func approveAndClose(_ window: NSWindow) {
        closeApproved = true
        window.performClose(nil)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}
```

- [ ] **Step 2: Rewire `Sources/tvmv/ViewerWindow.swift`** — replace the guard attachment:

```swift
        .background { WindowCloseGuard(
            isDirty: { model.isDirty },
            save: { model.save(); return !model.isDirty }
        ) }
```

with (uses Task 4's flush-only `flushEditorText()` — the flow must flush
WITHOUT saving so "Don't Save" works):

```swift
        .background { WindowCloseGuard(
            needsFlow: { model.isDirty || model.isEditing },
            flush: { await model.flushEditorText() },
            isDirty: { model.isDirty },
            save: { model.save(); return !model.isDirty }
        ) }
```

- [ ] **Step 3: Route ⌘S through the flush** — in the same file's `focusedSceneValue`, replace `save: { model.save() },` with:

```swift
            save: { Task { await model.flushAndSave() } },
```

- [ ] **Step 4: Build + full suite**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: build succeeds, 28/28, zero warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/tvmv/WindowCloseGuard.swift Sources/tvmv/ViewerWindow.swift Sources/tvmv/ViewerModel.swift
git commit -m "Async close flow: flush the editor bridge before the dirty prompt; Cmd-S flushes too"
```

---

### Task 6: Bundle + manual verification

**Files:** none expected (fixes get their own commits).

- [ ] **Step 1: Build and install**

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer fish build/bundle.fish`
Expected: `dist/TVMV.app` assembled, installed to `~/Applications`. (Launch with the full path `~/Applications/TVMV.app` — a stale copy exists in `/Applications` that `open -a TVMV` resolves to.)

- [ ] **Step 2: Open the standing test doc**

Run: `open -a ~/Applications/TVMV.app /private/tmp/claude-501/-Users-ulfnielsen-dev-tvmv/a3f50bf6-65b2-4388-8669-c9083c0fdf16/scratchpad/edit-test.md`
(Recreate it from the split-editing plan's Task 10 Step 1 if the scratchpad was cleaned.)

- [ ] **Step 3: Re-run the full split-editing manual checklist** (items 1–19 in `docs/superpowers/plans/2026-07-03-split-editing.md` Task 10 — every behavior must survive the engine swap), plus these CodeMirror-specific items:

20. **Typing latency:** on the mermaid/KaTeX test doc, sustained typing must feel immediate (the original complaint). Also verify with a large doc (paste the file into itself a few times).
21. **Markdown highlighting:** headings/emphasis/links styled in the editor; a ```swift fenced block gets code highlighting; soft wrap on long paragraphs; no line-number gutter.
22. **Undo:** ⌘Z / ⇧⌘Z with editor focus undo/redo typing. Then Edit-menu Undo/Redo items — if the menu swallows ⌘Z instead of CodeMirror receiving it, apply the spec's fallback (WKWebView subclass forwarding `undo:`/`redo:` to `CM.undo`/`CM.redo`) as a fix commit.
23. **Blur flush:** type, immediately click the preview, ⌘S — the just-typed characters are in the saved file.
24. **Close flow:** type (stay inside the 100 ms debounce — close immediately), click the window close button → prompt appears, all three buttons behave; ⌘W same; ⌘Q with a dirty window → prompt appears and quit is cancelled; resolve, ⌘Q again quits.
25. **Theme/typography live-apply:** flip light/dark in Settings while editing → editor follows (oneDark in dark mode); change mono font / size → editor follows.
26. **External reload while editing (clean):** editor content replaces, ⌘Z does NOT resurrect the old text.
27. **Dead-bridge save:** none observable normally — skip unless a crash occurs; the headless test covers the fallback.

- [ ] **Step 4: Fix anything that failed** (each fix: reproduce → fix → re-verify → own commit), then:

Run: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS.

- [ ] **Step 5: Final docs commit if checklist/plan changed**

```bash
git add -A docs/
git commit -m "CodeMirror editor: manual verification notes"
```
