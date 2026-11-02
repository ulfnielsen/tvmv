# Native single-surface editor (iOS) — design

**Date:** 2026-11-02
**Status:** Draft, pending user review
**Base spec:** [2026-10-14-native-editor-design.md](2026-10-14-native-editor-design.md).
This document lists only where iOS differs. Anything not mentioned here
works as the base spec says, as far as macOS has shipped it (v1.2.0).
**Also applies:** [2026-10-14-review-comments-design.md](2026-10-14-review-comments-design.md)
**Sibling port:** [2026-10-21-linux-native-editor-design.md](2026-10-21-linux-native-editor-design.md)

## Goal

Bring the macOS editor to iOS: one UIKit view that is both the reader and
the editor, with markup hidden, tables as grids, and review comments. It
replaces the WKWebView reader and the CodeMirror pane in the document
screen. The Markdown file stays the single source of truth, and nothing is
re-serialized.

iOS is now the only platform where you don't edit what you read. With this
port all three apps share one interaction model.

## Who it serves

- **iPad** is where real editing happens, often with a hardware keyboard.
  The macOS shortcuts must work there.
- **iPhone** is mostly for reading, plus small edits: fixing a typo,
  ticking a task, and adding or answering a review comment. All of those
  must be comfortable at phone width with the software keyboard.

## Goals, non-goals, anti-goals

- **Goals:**
  - Parity with what macOS shipped: hidden markup, per-span and
    whole-document reveal, lists, quotes, checkboxes, block images,
    tables as grids, review comments with cards, spelling, outline, links,
    reading position and bookmarks, find, settings, print/Share PDF.
  - Touch-first equivalents for everything macOS does with the pointer
    (hover, double-click, right-click).
  - **Inline images render as pictures on macOS and iOS** (decided with
    the user). Today macOS shows any image that is not alone in its
    paragraph (a badge, an image in a sentence or a table cell) as
    `![alt](path)` source, styled like raw HTML; the iOS web reader shows
    it as a picture. Fixed once in the shared layer, so both get it.
- **Non-goals (this project):**
  - Native rendering of syntax highlighting, KaTeX math and Mermaid. They
    show as source in the code style, as on macOS and Linux, and render in
    Share PDF. Native rendering of math and Mermaid is a later,
    cross-platform project (see Deferred).
  - The three-way merge, which macOS hasn't built either.
  - Pasting images into the document (see Deferred).
- **Anti-goals:** it is a failure, even if it technically works, when:
  - the file changes in any way the user didn't type (re-serialization,
    normalized whitespace, escaped CriticMarkup);
  - the iPhone reading experience gets worse than today's web reader for
    anything except highlighting, math and Mermaid;
  - the iOS editor drifts from macOS in what it hides, styles or does on a
    keystroke.

## Decisions

1. **Same interaction model as macOS.**
   - A document opens read-only. The toolbar pencil (and **⌘E** on a
     hardware keyboard) enables typing in the same view, with no swap and
     no jump.
   - While read-only the view is `isEditable = false`, `isSelectable =
     true` *(my call)*: there is no caret and the keyboard never comes up.
     A tap follows a link, ticks a checkbox or opens a review thread;
     elsewhere it does nothing. Long-press or double-tap selects, and the
     selection drives the edit menu (Show Markdown, Comment…, Suggest
     Edit…) and ⌘' on a hardware keyboard.
   - While editing, a tap places the caret as usual.
   - Markup is always hidden. Hardware-keyboard shortcuts are the macOS
     ones: **⌘'** reveals one span, **⌥⌘M** toggles all markup, **⌘B / ⌘I
     / ⌘K** wrap a selection, **⌘⇧M** comments, **⌘⇧E** suggests an edit.
2. **Touch reveal goes through the edit menu** *(my call)*. Double-tap
   selects a word on iOS and must keep doing so, so the macOS double-click
   reveal does not carry over. Instead:
   - The edit menu (`UIEditMenuInteraction`, shown on a selection, or on
     a tap on the caret while editing) gets **Show Markdown** when the caret or selection is in
     a reveal unit, and **Hide Markdown** inside a revealed one. Example:
     to fix a link's URL, switch to editing, tap in the link, tap the caret
     again, choose Show Markdown, edit the `(…)` part. Read-only, the same
     item appears on a selection.
   - The toolbar's overflow menu gets **Show Markdown** for the whole
     document (⌥⌘M).
   - A revealed span hides again when the caret leaves it, as on macOS.
3. **Formatting and review on touch also go through the edit menu**
   *(my call)*: Bold, Italic, Link (while editing), Comment… and Suggest
   Edit… (in read-only mode too). No custom keyboard accessory bar.
4. **Text stack: `UITextView` on TextKit 1,** built over an explicit
   `NSTextStorage` → `NSLayoutManager` → `NSTextContainer` stack so it is
   never TextKit 2. Markup is hidden with null glyphs in
   `NSLayoutManagerDelegate`, the same code as macOS (proven by the spike,
   below).
5. **Share the TextKit 1 layer with macOS** *(my call)*. NSLayoutManager,
   NSTextStorage, paragraph styles and glyph properties are the same API on
   both platforms, so the parts of the Mac view that only talk to TextKit
   move into a new SwiftPM target, `TVMVNativeText`, used by both apps:
   - the styler (`DocumentStyler`), the theme (`NativeTheme`), the
     layout-manager delegate (null glyphs, soft breaks), the drawing of
     bullets, numbers, checkboxes, quote rules, rules, code-block
     backgrounds, code pills, point markers and block images, the parse
     cycle (sync ≤ 64 KB, async above, latest wins, diff-bounded restyle),
     reveal state, image loading and decoding, and the reading-position
     geometry;
   - platform types go through small aliases (`PlatformFont`,
     `PlatformColor`, `PlatformImage`, `PlatformBezierPath`) and
     `#if os(...)` only where AppKit and UIKit really differ;
   - events, menus, the find UI, table grids and review cards stay per
     platform (`Sources/tvmv/` and `ios/Sources/`).
   This is a refactor of shipped Mac code, so it goes first, on its own,
   with the Mac test suite green before any iOS UI is built. The goal is the
   one Linux needed a golden corpus for: the platforms cannot drift.
6. **Saving stays with `DocumentGroup`.** iOS keeps today's `FileDocument`
   flow: every settled edit flows into the document binding and the system
   autosaves. There is no ⌘S and no close guard on iOS. External changes
   (another app, iCloud) arrive as a new document value; the view adopts the
   text in place and maps caret and scroll through the change, as macOS does
   without unsaved edits.
   - *(My call)* Edits reach the binding after a short debounce. Before an
     incoming value is adopted, any pending edit is flushed into the binding
     first, and an incoming value equal to what the view last pushed is
     ignored (an own-save echo). If the incoming text differs from a buffer
     that still has edits not yet in the binding, the buffer wins and is
     pushed; the system's version handling settles the file. An open
     composer or thread sheet closes when its anchor is gone.
7. **The web layer stays only for Share PDF** (and print, if added). The
   CodeMirror pane, `EditorBridge`, `EditorPaneView` and `PreviewWebView`
   leave the iOS app. With iOS done, no platform uses CodeMirror; deleting
   the vendored bundle and `editor.js` is the last build step.

## Evidence (throwaway spike, 2026-11-02)

A `TVMVSpike` app target (two files, about 200 lines) on branch
`spike/ios-native-editor`, iPhone 17 Pro simulator, iOS 26. It used
`MarkdownLayoutParser` and `EditRules` from `TVMVCore` unchanged and a copy
of the Mac glyph delegate.

- **Passed (7 unit tests, 1 UI test):**
  - The explicit stack gives a TextKit 1 view (`textLayoutManager == nil`),
    and UIKit calls `shouldGenerateGlyphs`.
  - Hidden `**` takes no width: the "b" of **bold** sits where the first
    `*` would be, and the stars' glyphs are `.null`.
  - A heading's `# ` hides at the line start.
  - Fence lines take no height: a fenced block stands as tall as an
    indented one. As on macOS, an all-hidden line's glyphs join the line
    before; its collapsed height is on the fragment holding its newline.
  - The caret snaps out of a hidden run (`EditRules.snapCaret` from
    `textViewDidChangeSelection`), and the caret rects either side of a
    hidden `**` agree.
  - Typing through `insertText` and through the real software keyboard
    (`Typed **bold** and *it* here`) restyles live and hides the new
    markup; the source keeps the markup byte for byte.
- **Not tested:** selection handles and the magnifier across hidden runs,
  autocorrect and predictive text next to hidden markers, marked text (IME),
  dictation, spelling underlines and exemptions, VoiceOver, hardware
  keyboard arrows and word motion, performance at 1 and 5 MB, tables,
  cards.

## What renders how

The same as macOS, except:

| Construct | Display | Notes |
|---|---|---|
| Math, Mermaid, HTML blocks, front matter | Source, in the code style | As macOS and Linux today |
| Fenced code | Mono, block background, no highlighting | Today's iOS reader highlights; accepted loss |
| Block images | As macOS | Local images load only where the app can read them (see Risks) |
| Inline images (new, macOS too) | The picture, in the line | Below |
| Tables | Grid of cell views (below) | Scrolls sideways when wider than the column |
| Review cards | Margin column on regular width, sheet on compact (below) | |

## Inline images (macOS and iOS)

- **Parser:** `MarkdownLayout` gains `inlineImages` (source range, address,
  alt) for every image that is not a block image, including images inside
  links and table cells. The `.image` style run stays for revealed source.
- **Display:** the same technique as point-comment markers. The source
  hides except one carrier character, set clear with a kern that reserves
  the picture's width; the view draws the picture there. Its height is
  capped at 1.4 em (and its width at the text column), scaled to keep the
  aspect ratio. The cap keeps a picture inside the 1.7 em body line, so a
  picture never raises its line: a paragraph keeps its even line spacing
  (a badge or icon reads as part of the text). Loading, caps and decoding
  reuse the block-image path. While loading or after a failure, the alt
  text shows in the muted style (with no alt, the file name; with neither,
  the source).
- **Editing:** the image is one reveal unit; Show Markdown, ⌘' or the
  caret entering it reveals `![alt](path)`. The caret passes the image as
  one character. An image inside a link follows the link on tap/click.
- **Linux** follows later (see Deferred).
- The golden-corpus key follows with the Linux port.

## Editing rules

`EditRules` is used as is. UIKit wiring differs from AppKit:

- **Caret snap** runs in `textViewDidChangeSelection`, with the direction of
  travel taken from the previous selection (as in the spike).
- **Delete retarget and prefix removal** run in
  `textView(_:shouldChangeTextIn:replacementText:)`: a one-character delete
  that lands on hidden markup is replaced by the retargeted edit.
- **List continuation** on Return runs there too.
- **Hardware keys:** `UIKeyCommand`s for the shortcuts above; Tab /
  Shift-Tab in tables.
- **Undo:** one `UndoManager` for the document, so table cells and review
  actions are one stack, as on macOS. The system undo gestures (shake,
  three-finger swipe) and the edit menu's Undo use it.
- **Marked text:** no restyle or caret snap while `markedTextRange` is set
  (the Mac view's `unmarkText` hook has the same role).

## Table grid

As macOS (`TableGridView`: one small text view per cell, edits patch the
hidden source through the document's edit path, `|` escaped, one undo
stack), with these differences:

- **Narrow screens:** a grid wider than the text column scrolls sideways
  inside its own reserved room; the page never scrolls sideways.
- **Row and column commands** come from the cell's edit menu (insert
  above/below/left/right, delete, align), as Linux's right-click menu does.
  The macOS hover handles do not exist on touch.
- **Hardware keyboard:** Tab, Shift-Tab and Return move between cells, and
  ⌘' reveals the table's source, as macOS.

## Review comments

The core (`ReviewMarkup`, `ReviewSpans`, `ReviewLayout`, `ReviewOperations`,
card models and stacking) is shared. The UI differs by width:

- **Regular width (iPad, full or large split):** cards in a margin column
  beside their anchors, stacked without overlap, as macOS.
- **Compact width (iPhone, narrow iPad split):** no column. Anchors keep
  their inline styles, and each thread shows a small marker at the right
  edge of its first anchor's line. The thread opens in a sheet (medium and
  large detents): entries, Reply field, and Accept / Reject or Resolve.
  Next and Previous Thread move the sheet along.
  - *(My call)* Read-only, tapping an anchor or its marker opens the
    sheet. While editing, only the marker does: a tap in commented text
    places the caret, so small edits near comments are not interrupted.
- **Creating:** Comment… and Suggest Edit… in the edit menu, or ⌘⇧M / ⌘⇧E,
  open the composer: a card in the column on regular width, a sheet on
  compact. Both work read-only.
- **The Review menu** is in the toolbar overflow: Comment…, Suggest Edit…,
  Next / Previous Thread, Accept All, Reject All.
- **Author:** iOS has no git config, and no public API gives the owner's
  name. *(My call)* A new iOS-only setting, **Review name**, holds it. The
  first Comment… or Suggest Edit… with no name set asks for one in the
  composer (one field, prefilled empty) before posting, so no entry is ever
  signed with a placeholder. macOS keeps git `user.name` and does not show
  the setting.

## Reader features

- **Outline:** the existing sheet, fed from the layout's headings.
- **Links:** a tap while read-only follows the link; while editing, the
  edit menu offers Open Link. `#…` scrolls to the heading; anything else
  opens externally.
- **Reading position and bookmarks:** stored as offsets, as macOS. The
  existing iOS fraction entries are read once, then rewritten as offsets.
  The percentage indicator and its bookmark menu stay.
- **Find:** `UITextView`'s built-in find (`UIFindInteraction`), searching
  the source as macOS does. It replaces today's custom find bar.
- **Settings:** the existing sheet. Fonts, size, measure, full width and
  theme apply to the native view live. A **Review name** field is added.
- **Spelling:** UIKit's spell checker. It runs only while editing (UIKit
  checks the first responder). See Risks for exemptions.
- **Share PDF:** the existing web pipeline, fed the current text.

## Components

- **New target `TVMVNativeText`** (macOS and iOS), from decision 5.
- **Mac app (`Sources/tvmv/`):** `DocumentTextView` keeps AppKit events,
  menus, the find bar, the hover handles and cards, now built on
  `TVMVNativeText`.
- **iOS app (`ios/Sources/`):**
  - `DocumentTextView` (iOS): the `UITextView` subclass on the shared layer,
    with touch, edit menu, key commands and find.
  - `NativeDocumentView`: the `UIViewRepresentable` and its controller
    (scroll to offset, reading position, outline jumps), mirroring the Mac
    `NativeDocumentView`.
  - `TableGridView` (iOS) and `ReviewCardView` / thread sheet (iOS).
  - `DocumentScreen` hosts the native view; the editor pane and the preview
    web view go.
- **`ViewerModel`:** the web-reader and CodeMirror paths become unused on
  iOS. Once iOS ships they are unused everywhere except Share PDF and print
  and can be cut down.

## Performance targets

The simulator gates CI. The targets hold on the oldest physical device
available for testing (iOS 26 runs back to A13 iPhones; an older device
only makes the check stricter) *(my call)*:

- Main-thread work per keystroke under 16 ms at 1 MB; parse off the main
  thread above 64 KB.
- Open to first paint under 300 ms at 1 MB.
- No full-document main-thread work for a keystroke, caret move or reveal
  over 64 KB.

## Testing

- **Shared layer:** the Mac's existing native-view tests move with the code
  into `TVMVNativeText` tests and run on both macOS and the iOS simulator.
- **iOS unit tests (hosted):** the spike's geometry checks made permanent
  (hidden width, collapsed fences, caret rects, snap), plus delete retarget,
  list continuation, table cell patches, and review actions with undo.
- **UI tests:** read-only tap does not raise the keyboard; pencil enables
  typing; checkbox toggle while read-only; Show Markdown from the edit
  menu; table cell edit; comment from a selection, reply, resolve, undo;
  compact-width thread sheet.
- **Manual pass, right after step 3:** selection handles and magnifier
  across hidden runs, autocorrect and predictive text beside markers,
  Japanese and Chinese input inside emphasis, dictation, VoiceOver reading
  order, hardware keyboard word motion and Shift-selection on iPad.

## Build order

*(My call)* `main` stays releasable on both platforms at every step. Until
step 7 the iOS native view is behind a developer setting (off by default),
and the shipped web reader and CodeMirror pane stay as they are, so no iOS
build is worse than today's in the meantime. The reading-position migration
only runs in the native view, and it keeps the old fraction entries until
the native view is the default.

1. **Extract `TVMVNativeText`** from the Mac view. No behavior change; the
   Mac test suite and a manual Mac pass stay green.
2. **Inline images** in `TVMVNativeText`, shipped on macOS first (with
   golden-corpus fixtures for `inlineImages`).
3. **iOS view, read-only then editing:** `DocumentTextView` (iOS) on the
   shared layer, the pencil, edit rules, edit-menu reveal and formatting,
   hardware shortcuts. Then the manual pass above.
4. **Reader features:** outline, links, reading position and bookmarks,
   find, settings, Share PDF.
5. **Lists, quotes, checkboxes and images** (mostly free from the shared
   layer; this step is touch handling and image access).
6. **Table grid.**
7. **Review comments:** column, compact sheet, composer, Review menu,
   Review name setting. Then the native view becomes the default and the
   web reader and CodeMirror pane leave `DocumentScreen`.
8. **Cleanup:** delete the vendored CodeMirror bundle, `editor.js`,
   `EditorBridge` and the unused `ViewerModel` paths; update the README.

## Risks

- **Spelling exemptions.** UIKit has no equivalent of AppKit's
  `shouldSetSpellingState`: code, URLs and review ids may get red
  underlines while editing. Check during step 3. Fallbacks, in order:
  accept it (checking only runs while editing), or turn spelling off while
  the caret is in an exempt range.
- **Selection handles and the magnifier** around null glyphs are untested;
  the handles may land inside hidden runs. Mitigation: snap the selection
  ends in `textViewDidChangeSelection` as `EditRules` already does for
  Shift-selection on macOS.
- **Autocorrect and IME** may replace text across a hidden delimiter, or
  restyle mid-composition. The marked-text guard covers the second; the
  manual pass decides whether the first needs a guard in
  `shouldChangeTextIn`.
- **Local images.** A document opened from Files gives the app access to
  that file only, not its folder, so relative images next to it may not
  load. Today's web reader has the same limit. If it matters, a later step
  can ask for folder access once (`UIDocumentPickerViewController` for the
  folder, kept as a security-scoped bookmark).
- **The extraction touches shipped Mac code.** Step 1 is behavior-neutral
  and lands alone so a regression is easy to bisect.
- **TextKit 1 on iOS.** Supported on iOS 26; if it is ever deprecated,
  hiding moves to TextKit 2 layout fragments on both platforms at once,
  inside `TVMVNativeText`.

## Deferred

- Native rendering of KaTeX math and Mermaid (and possibly highlighting),
  for all three platforms.
- The three-way merge, following macOS.
- Pasting images (needs write access to the document's folder).
- Grammar checking.
- Folder access for relative images, if the limit above proves annoying.
- Inline images on Linux (port `inlineImages` and the drawing, as for
  block images).
