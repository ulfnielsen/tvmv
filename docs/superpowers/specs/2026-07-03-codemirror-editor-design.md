# CodeMirror 6 editor pane — design

**Date:** 2026-07-03
**Status:** Draft, pending user review
**Supersedes:** the NSTextView editor pane from
`2026-07-03-split-editing-design.md` (all other behavior from that spec —
split UX, save semantics, watcher rules, close protection, click-to-jump —
carries over unchanged unless amended here).

## Goal

Replace the NSTextView editor pane with an embedded CodeMirror 6 source
editor: Markdown syntax highlighting, mature editing behavior, and an end to
the per-keystroke SwiftUI churn behind the reported typing lag. Vendored,
fully offline, like every other web asset in tvmv.

## Decisions (user-confirmed / assumed while away — flag on review)

1. **Engine:** CodeMirror 6 (user-confirmed "CodeMirror 6 now").
2. **Editor feel (assumed, recommended default):** prose style — soft
   line-wrapping, no line-number gutter, Markdown highlighting (with fenced
   code-block languages via `@codemirror/language-data`), active-line
   highlight. Both wrap and gutter are one-line extension toggles if the
   user wants them changed.
3. **Hosting:** a second WKWebView dedicated to the editor (approach A).
   The preview webview, native HSplitView divider, print, and find are
   untouched.
4. **Find (⌘F) stays preview-only**, as in the v1 spec. CM's own search
   panel is not wired up.
5. **NSTextView pane is deleted**, not kept behind a setting. `LineIndex`
   and its tests go with it if nothing else consumes them (the editor now
   reports lines itself).

## Approaches considered

- **A. Second WKWebView for the editor (chosen).** Smallest blast radius:
  preview pipeline, native divider, focus model per NSView. Cost: a second
  web process (~tens of MB; the app already ships mermaid at 3&nbsp;MB —
  weight is not the constraint here) and a second JS bridge.
- **B. One webview, HTML-internal split.** Single JS context makes
  editor↔preview sync trivial, but restructures the preview page, replaces
  the native divider with a JS one, and entangles print/find/outline.
  Rejected.
- **C. Polish NSTextView.** Declined by the user.

## Architecture

### Event-driven bridge (the load-bearing change)

The NSTextView design had the model *pull* from the editor synchronously
(`cursorLine`, `topVisibleLine()`). A webview can only be queried
asynchronously, so the CM editor *pushes* instead. Consequences:

- Keystrokes live entirely inside CodeMirror. The editor posts a debounced
  (~100 ms) `textChanged` message with the full document; `model.text` — and
  therefore every SwiftUI body re-evaluation hanging off it — updates at
  that cadence, not per keystroke. This is the direct fix for the typing
  lag (per-keystroke `@Published` churn re-ran menu command publication,
  two window representables, and a full-document string compare).
- The editor posts `cursorLine` and `topVisibleLine` events (rAF-throttled
  in JS, debounced 150 ms in the model as today); the model's existing
  `editorScrolled`/`editorCursorMoved` sync logic keeps its shape but
  receives lines instead of computing them.
- The model caches the latest position from these events
  (`EditorPosition {cursorOffset, topLine}` survives), so ⌘E-off capture
  stays synchronous.

### Components

**`build/editor-bundle.fish` + committed bundle** — builds
`Sources/tvmv/Resources/web/vendor/codemirror/codemirror.bundle.js` (an
IIFE exposing `window.CM`) once via `npx rollup` from a pinned package
list (`codemirror`, `@codemirror/lang-markdown`,
`@codemirror/language-data`, minimal extensions). The bundle is committed,
like every `vendor/` asset; the build script is only needed to upgrade.
Node is available on this machine (v26). Pin exact versions in the script.

**`Sources/tvmv/Resources/web/editor.html` + `editor.js` + `editor.css`** —
the editor page, served over the existing `tvmv-asset://app/` scheme.
`editor.js` exposes `window.tvmvEditor`:
- `setText(text, {resetHistory})` — programmatic replacement (external
  reload, discard). `resetHistory: true` rebuilds the EditorState so ⌘Z
  cannot resurrect replaced text (same hazard class the NSTextView version
  fixed with `removeAllActions`).
- `scrollToLine(line, placeCursor)` / `restore(cursorOffset, topLine)` /
  `focus()` / `getText()` (returns the doc for the save flush).
- `applyStyle(json)` — mono font, base size, light/dark theme, mirroring
  the preview's `applyStyle` contract with a reduced key set.
- Posts: `ready`, `textChanged {text}` (debounced ~100 ms, flushed
  immediately on blur), `cursorMoved {line, offset}`,
  `scrolled {topLine}`.
- CM extensions: markdown (+ code-language data), history, default keymap,
  drawSelection, highlightActiveLine, `EditorView.lineWrapping`.

**`CodeMirrorEditorPane.swift`** — NSViewRepresentable wrapping the editor
WKWebView (its own `WKWebViewConfiguration`, message handler name
`tvmvEditor`, reusing `AssetSchemeHandler` for `tvmv-asset://app/`).
Replaces `EditorPane.swift`. Exposes an `EditorBridge` controller
(commands above, async where they cross the bridge) and event callbacks.
Created/destroyed with `model.isEditing` exactly as today; on `ready`, the
model seeds it with `setText` + `restore`/anchor position + `focus`.

**`ViewerModel` changes** — same public editing API and state machine
(`isEditing`, `isDirty`, `externalChangePending`, `reload(force:)`,
`discardAndReload`, `previewClicked`); internals adjust:
- `attach(editor:)` takes the `EditorBridge`; positioning waits for the
  editor's `ready` event (the anchor logic — restore vs re-anchor to the
  preview, `editorCloseSync` await — is unchanged).
- `editorScrolled(topLine:)`/`editorCursorMoved(line:)` receive lines from
  events.
- Position capture on close reads the event-fed cache (synchronous, as
  today).
- **Save flush:** `save()` stays synchronous over `model.text`. The two
  entry points that race typing gain a flush: the ⌘S menu action becomes
  `Task { await flushEditorText(); save() }` (one `getText()` round-trip
  adopts the authoritative doc), and the close path flushes before its
  prompt (below). The blur-flush covers everything else (any click outside
  the editor delivers pending text before the user can act on stale state).

**`WindowCloseGuard` rework (async close flow)** — `windowShouldClose` can
no longer prompt synchronously, because a correct prompt must follow a
bridge flush. New flow: when `isDirty` (or the editor pane is open),
`windowShouldClose` returns `false` and starts a `Task`: flush editor text
→ if clean, mark `closeApproved` and re-`performClose()` → else run the
same Save / Don't Save / Cancel alert on the main actor, then save (staying
open on failure) or discard, mark `closeApproved`, and `performClose()`.
The delegate returns `true` immediately when `closeApproved` is set (and
resets it). Clean windows keep today's fast path. `applicationShouldTerminate`
switches to `.terminateLater`-style handling only if testing shows the
per-window veto no longer suffices; first attempt keeps the current loop
(each `windowShouldClose` call now kicks off the async flow and returns
false, so quit must tolerate deferred closes — the plan must test ⌘Q
explicitly).

### Deletions

`EditorPane.swift` (NSTextView version), `LineIndex.swift`,
`LineIndexTests.swift` (sole consumer was the deleted pane). `EditorPosition`
moves next to the bridge.

## Data flow

```
CM keystrokes ──(100ms debounce / blur flush)──> textChanged ──> model.textEdited
model.textEdited ──(250ms debounce)──> renderCurrent ──> preview (unchanged)
CM scroll ──> scrolled{topLine} ──> model ──> preview scrollToSourceLine (unchanged shape)
CM cursor ──> cursorMoved{line} ──> model ──> preview revealSourceLine (unchanged shape)
preview click ──> sourceClick{line,endLine,word,ordinal} ──> model.previewClicked
                 ──> SourceClickResolver ──> bridge.placeCursor{line,column}
                 (no word under the pointer ──> bridge.scrollToLine, the original behaviour)
⌘S ──> flush(getText) ──> save()   |   close ──> flush ──> prompt ──> save/discard
external reload / discard ──> bridge.setText(resetHistory: true)
```

## Error handling

| Failure | Behavior |
|---|---|
| Editor page fails to load / JS error | Surface via the existing `errorMessage` path; ⌘E still toggles the pane away. No read-only fallback pane (YAGNI) — a dead editor is immediately visible because typing does nothing. |
| `getText()` flush fails (bridge gone) | Fall back to `model.text` (last debounced state); save proceeds — worst case loses <100 ms of keystrokes in a scenario where the editor process died anyway. |
| Save write fails | Unchanged: alert, stays dirty; async close flow keeps the window open. |
| Style/theme apply before `ready` | Queued on the `ready` event, mirroring the preview's `isReady` gating. |

## Risks

- **⌘Z / Edit-menu routing.** CM handles Mod-Z via its keymap when the
  webview has focus; macOS menu key-equivalents *should* defer to the
  focused WKWebView (Safari-derived apps rely on this), but if the Edit
  menu swallows undo, fallback is a small WKWebView subclass forwarding
  `undo:`/`redo:` to `CM.undo/redo`. Test first, in the plan's earliest
  editor-page task.
- **Async close flow** replaces a working synchronous guard; it's the
  riskiest rework. The plan must keep the old behavior for the clean-window
  path and test the dirty paths (close button, ⌘W, ⌘Q) manually.
- **Bundle build reproducibility.** Pin versions; commit the bundle so CI
  and offline builds never need npm.
- **Two web processes** per editing window. Accepted (weight comparable to
  the existing vendored assets; panes are created only while editing).

## Testing

- Existing `ViewerModelEditingTests` (30 tests) must keep passing —
  the model's dirty/save/reload state machine is intentionally untouched;
  tests construct the model headless exactly as before.
- New headless tests where logic allows: flush-fallback path
  (`flushEditorText` with no bridge → save uses cached text).
- JS untested by infra (unchanged constraint); the manual checklist is
  re-run in full (items 1–19), plus new items: undo via ⌘Z and Edit-menu,
  typing latency subjectively fixed on the mermaid test doc, fenced code
  highlighting inside the editor, ⌘W/⌘Q through the async close flow,
  blur-flush (type, immediately click the preview, ⌘S — nothing lost).
- Perf check: with the editor open on the test doc, typing must not
  re-render SwiftUI per keystroke (verify via a debug counter or Instruments
  during the manual pass).

## Out of scope

- CM search panel, vim/emacs keymaps, autocompletion, linting.
- Word-level (sub-block) sync precision — still block-level via sourcepos.
- WYSIWYG/live-preview editing (Milkdown/ProseMirror) — explicitly still
  the bigger separate project.
- Editor settings UI (wrap/gutter toggles) — defaults only for now.

## Estimate

3–4 focused days: bundle + editor page + bridge (day 1), pane + model
rewiring + flush semantics (day 2), async close flow + deletions + tests
(day 3), manual pass + fixes (day 4).
