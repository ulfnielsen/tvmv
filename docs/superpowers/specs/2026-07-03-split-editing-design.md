# Split-pane Markdown editing — design

**Date:** 2026-07-03
**Status:** Draft, pending user review

## Goal

Add simple editing to tvmv as a split view: a raw Markdown editor pane beside the
existing rendered WKWebView preview. Scroll position, cursor, and focus must be
preserved when moving back and forth between viewing and editing, and the two
panes must stay in sync while editing.

## Decisions (assumptions made while user was away — confirm on review)

1. **Mode model:** ⌘E toggles the editor pane. Default remains today's clean
   view-only window. ⌘E opens the split (editor left, preview right); ⌘E again
   closes it. Precedent: Obsidian uses ⌘E for the same toggle.
2. **Editor surface:** native `NSTextView` (via `NSViewRepresentable`), not
   SwiftUI `TextEditor` — we need cursor/scroll APIs, the undo manager, and a
   monospaced font. Not a web-based editor.
3. **Preview updates live** while typing, debounced ~250 ms, preserving preview
   scroll position.
4. **Save is explicit** (⌘S), with a dirty indicator (window's `isDocumentEdited`
   dot) and a Save/Don't Save/Cancel prompt when closing a dirty window. No
   autosave in v1.
5. **Sync is sourcepos-based** (see Approaches below) and one-directional while
   split: the editor drives the preview. Verified: the vendored cmark-gfm
   supports `CMARK_OPT_SOURCEPOS`, emitting `data-sourcepos` on block elements.

## Approaches considered

- **A. Scroll-ratio sync** — map panes by scrollTop fraction. Trivial to build
  on the existing `getScrollRatio`/`setScrollRatio`, but imprecise: rendered
  height is not proportional to source lines (images, mermaid diagrams, KaTeX),
  so the panes drift apart exactly in the documents that matter.
- **B. Sourcepos anchor sync (chosen)** — render with `CMARK_OPT_SOURCEPOS` so
  every block element carries its source line range; map editor line ↔ preview
  element directly. Precise entry/exit positioning and live sync; modest extra
  JS and renderer plumbing.
- **C. CodeMirror editor inside the WebView** — editor and preview both in web
  land, sync in JS. Rejected: vendoring a JS editor and bridging native
  menus/undo/focus into it is far more work than the feature warrants, and it
  drifts toward the "replace the renderer" project explicitly deferred.

## Architecture

Text has a single owner: `ViewerModel.text` (already exists, becomes
`@Published`). The editor edits it; the preview renders it; save writes it.

```
NSTextView edits ──> ViewerModel.text ──(debounce 250ms)──> renderCurrent() ──> WKWebView
                        │                                        ▲
                        ├── isDirty = (text != lastSavedText)    │ data-sourcepos
                        └── save() ──> disk (suppress FileWatcher)
Editor scroll/cursor ──> topmost line / cursor line ──> scrollToSourceLine() in preview
```

### Components

**`MarkdownRenderer.swift`** — `renderHTML(_:sourcePos: Bool = false)`. The app
passes `true`; the default keeps QuickLook/Thumbnail output byte-identical
(those targets compile this same source file outside SwiftPM).

**`EditorPane.swift` (new)** — `NSViewRepresentable` wrapping `NSTextView` in an
`NSScrollView`. Monospaced system font, standard undo/redo via the text view's
undo manager, no rich text. Exposes an `EditorController` (mirroring the
`MarkdownWebController` pattern) with: get/set cursor line, get topmost visible
line, scroll to line, focus. Reports text changes and cursor/scroll movement to
the model via callbacks. The view stays in the hierarchy when the pane is
hidden, so its cursor and scroll state survive toggles for free.

**`MarkdownWebController` additions** — two JS-backed calls:
- `topVisibleSourceLine() -> Int?` — first element with `data-sourcepos` whose
  box intersects the viewport top; returns its start line.
- `scrollToSourceLine(_ line: Int)` — scroll the element whose sourcepos range
  covers (or is nearest below) the line into view near the viewport top.
JS lives in `boot.js` alongside the existing `window.tvmv` API.

**`ViewerModel` additions** — `isEditing`, `isDirty`, `lastSavedText`, the
debounced re-render, `save()`, and the sync orchestration. `reload()` gains
self-write suppression. Init gains the document's `encodingUsed` so saves
round-trip the original encoding.

**`ViewerWindow`** — the detail column becomes: `HSplitView { EditorPane; webView }`
when editing, just `webView` otherwise. Divider fraction persisted in
`AppSettings`. Editor pane appears/disappears with the toggle.

**`ViewerCommands`** — two new entries following the existing
`focusedSceneValue` pattern: Toggle Editing (⌘E) and Save (⌘S, disabled when
not dirty or no `fileURL`).

**Close guard (new, `WindowCloseGuard`)** — extends the existing `WindowChrome`
NSWindow access: installs a proxy `NSWindowDelegate` that forwards everything
to SwiftUI's original delegate but intercepts `windowShouldClose` to run a
Save/Don't Save/Cancel `NSAlert` when dirty. This is the one integration point
that touches SwiftUI internals; if it proves fragile, fallback is documented in
Risks.

`DocumentGroup(viewing:)` stays as-is; `MarkdownDocument.fileWrapper` continues
to throw. Save bypasses the SwiftUI document machinery entirely and writes via
`Data.write(to:options:.atomic)` to `fileURL`.

## Focus / scroll / cursor rules

- **Entering edit mode (first time in a window):** editor scrolls to the
  preview's topmost visible source line; cursor at the start of that line;
  keyboard focus moves to the editor.
- **Re-entering edit mode:** the editor keeps its previous cursor and scroll
  (view stays alive) — *unless* the preview's topmost visible line changed
  while the editor was hidden, in which case the editor re-anchors to the
  preview position (rule: "the pane you interacted with last wins").
- **While split:** editor drives preview. On cursor move/typing, if the
  cursor's block is out of the preview viewport, preview scrolls to it. On
  editor scroll, preview follows the topmost visible line. Preview→editor sync
  is deliberately out of scope for v1 (avoids feedback loops).
- **Leaving edit mode:** focus returns to the web view; the preview does not
  jump (it is already synced).
- **Live re-render while typing** preserves the preview's scroll by anchoring
  to the topmost visible sourcepos line (better than today's ratio-based
  preservation, which stays for external reloads of non-edit windows).

## Save & file watching

- ⌘S writes `text` to `fileURL` atomically, using the document's original
  encoding (`MarkdownText` gains an `encode` counterpart to `decode`).
- `FileWatcher` self-write suppression: the model sets a flag around its own
  write and additionally compares the on-disk content hash against
  `lastSavedText` when the watcher fires; matching content is ignored. (Both,
  because atomic saves fire rename events with timing that a flag alone can
  miss.)
- **External change while clean:** reload both editor text and preview
  (today's behavior, extended to the editor).
- **External change while dirty:** never clobber the editor. Show a banner in
  the editor pane — "File changed on disk — Reload (discards your edits)" —
  and leave the choice to the user.
- Save failure (permissions, volume gone): `NSAlert` with the error; document
  stays dirty.
- No `fileURL` (should not occur under `DocumentGroup(viewing:)`, but the type
  is optional): Toggle Editing is disabled.

## Error handling summary

| Failure | Behavior |
|---|---|
| Save write fails | Alert, stays dirty |
| External edit while dirty | Banner, user chooses |
| Sourcepos lookup misses (line in no block) | Fall back to nearest following block, else ratio |
| JS bridge unavailable (page not ready) | Sync calls no-op, as existing controller calls do |

## Testing

- `MarkdownText` encode/decode round-trip per supported encoding.
- `renderHTML(sourcePos: true)` emits `data-sourcepos`; `false` output unchanged.
- Line↔element mapping: pure-Swift parsing of sourcepos attributes unit-tested;
  JS side kept trivial.
- FileWatcher suppression: own-write ignored; external write triggers callback.
- Save: bytes on disk match, encoding preserved, dirty flag cleared.
- Manual: toggle round-trips (scroll/cursor/focus), live preview with mermaid/
  KaTeX docs, close-guard alert paths, divider persistence.

## Out of scope (v1)

- Preview→editor scroll sync; find (⌘F) in the editor (stays preview-only);
  outline clicks moving the editor; editor syntax highlighting; autosave;
  editor font preferences; any QuickLook changes.

## Risks

- **Close guard delegate proxy** may fight SwiftUI's window management across
  macOS versions. Fallback if it breaks: keep the dirty dot, and on
  `windowWillClose` write an emergency backup beside the file
  (`<name>.md.tvmv-unsaved`) rather than prompting.
- **Sourcepos + GFM extensions:** table/tasklist extension renderers must also
  emit sourcepos (upstream code suggests they do via the shared renderer path);
  verify early in implementation, else those blocks fall back to
  nearest-neighbor mapping.

## Estimate

Roughly 2–3 focused days: editor pane + save path (day 1), sourcepos sync +
focus rules (day 2), close guard + watcher edge cases + tests (day 3).
