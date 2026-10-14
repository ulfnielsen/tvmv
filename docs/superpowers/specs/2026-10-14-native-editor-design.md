# Native single-surface editor (macOS) — design

**Date:** 2026-10-14
**Status:** Draft, pending user review
**Companion spec:** [2026-10-14-review-comments-design.md](2026-10-14-review-comments-design.md) (builds on this one)

## Goal

Replace the macOS split pane (CodeMirror source + WKWebView preview) with one
native view that is both the reader and the editor. Markdown renders in place
with its markup hidden, so you edit what you read. Native spelling and grammar
come with it. The Markdown file stays the single source of truth. Nothing is
ever re-serialized from a model, so the user's exact source formatting
survives.

iOS and Linux are out of scope. They keep the current web reader and
CodeMirror editor until they get their own native editors, so the web layer
stays in the repo.

## Decisions

1. **One view for reading and editing.** A document opens read-only. ⌘E
   enables typing in the same view, with no swap and no jump. Selecting,
   revealing markup, ticking task checkboxes and commenting all work in
   read-only mode.
2. **Markup is always hidden.** It is not revealed on the caret's line. Typing
   `*word*` simply renders italic. Markup is shown only on request:
   - **Per span:** double-click a formatted span, or press **⌘'** with the
     caret in it. The markup hides again on **Esc**, or when the caret leaves
     the span.
   - **Whole document:** **⌥⌘M** (Show Markdown) toggles all markup.
3. **Native text stack.** `NSTextView` runs in **TextKit 1** mode. Markup is
   hidden with null glyphs in `NSLayoutManagerDelegate`. TextKit 2 has no
   equivalent.
4. **Parsing uses cmark-gfm,** the same pinned library that renders print and
   QuickLook, so the editor and the printed output cannot disagree about what
   the Markdown means. Only the blocks around an edit are re-parsed.
5. **Tables are an editable grid.** Each cell is a small native text view.
6. **Math, Mermaid, raw HTML blocks and front matter are embedded blocks.**
   They are rendered to images by an offscreen copy of the existing web layer.
   Double-click or ⌘' reveals the source.
7. **Save stays explicit (⌘S).** No autosave for now.
8. **External changes are merged three-way, never through a banner.**
   Overlapping changes become review suggestions (see the companion spec).
9. **Custom CSS is dropped on macOS.** Print and QuickLook use the built-in
   theme. Styling customization will be revisited separately.

## Evidence (throwaway spikes, 2026-10-14)

- **The native spike** (a single-file AppKit app, about 500 lines, kept outside
  the repo) verified on macOS 27:
  - Null-glyph hiding leaves the text byte-identical.
  - `textView(_:shouldSetSpellingState:range:)` exempts code, URLs and review
    ids from spelling: only real misspellings were flagged.
  - The caret-snap and delete-retarget rules, per-span reveal, ⌥⌘M, and
    collapsing code-fence lines while still drawing the block as code all
    work.
  - The review markup renders, and accept, reject, resolve and reply all
    work, with undo restoring the text exactly.
  - 22 scripted checks passed.
- **The web-editor research** ruled out the alternatives:
  - ProseMirror, TipTap and Milkdown rewrite 20–44 of the 47 lines in a
    round-trip fixture, and the remark parser that Milkdown uses escapes
    CriticMarkup.
  - `contenteditable` over the cmark-rendered HTML has no reliable way to map
    edits back to the source.
  - A CodeMirror live preview was viable, but its spelling support in WebKit
    is weak.
- **The pinned cmark-gfm:**
  - HTML output carries source positions only per block.
  - The AST has inline positions, but they are wrong after a backslash hard
    break, exclude code-span backticks, and shift after entities.
  - Footnotes work once `CMARK_OPT_FOOTNOTES` is set; TVMV does not set it
    today.

## What renders how

| Construct | Display | Editing |
|---|---|---|
| Emphasis, strong, strikethrough, inline code, links, autolinks | Native attributes; delimiters hidden | Type through; reveal shows delimiters |
| Headings (ATX and setext) | Heading font; `#`s or underline hidden | Backspace at start removes the prefix |
| Lists, task lists | `-` / `1.` replaced by a drawn bullet or number with a hanging indent; `[ ]` becomes a checkbox | Return continues the list; Return on an empty item ends it; checkbox clicks toggle `[ ]`/`[x]` even when read-only |
| Blockquotes | `>` hidden; left rule drawn | Prefix rules as for lists |
| Fenced and indented code | Mono font, block background drawn full-width; fence lines collapsed to zero height | Caret passes over the fence lines; reveal shows them |
| Thematic break | Drawn rule | Reveal shows source |
| Images | Native image from the local file | Reveal shows `![alt](path)` |
| Tables | Editable grid (below) | Cells edited in place; ⌘' shows the raw pipe table |
| `$…$`, `$$…$$`, Mermaid, HTML blocks, front matter | Embedded image, rendered offscreen | Reveal shows source; re-rendered on leaving it |
| Review markup | See companion spec | |

Spelling is exempt in code, URLs, embedded-block source, and review ids and
labels.

## Editing rules

These are pure functions in `EditRules`, tested without UI:

- **Caret snap:**
  - A zero-length selection never rests strictly inside a hidden run.
  - Movement passes over the run in its direction of travel.
  - A run at the start of a paragraph (a heading, list or quote prefix)
    always snaps to its end, so typing at a line's visual start stays inside
    the construct.
  - Collapsed fence lines pass in the direction of travel. Collapsed review
    thread definitions push the caret back out.
- **Inner edges:** the caret may sit just inside a closing delimiter, and
  typing there extends the formatting, as in a word processor.
- **Delete retarget:** a single-character delete that lands on hidden markup
  deletes the nearest visible character in that direction instead. Backspace
  just after a hidden line prefix removes the whole prefix.
- **⌘B, ⌘I and ⌘K** wrap a non-empty selection in `**`, `*` or `[…]()`, and
  unwrap it if it is already wrapped. With no selection they do nothing.
- **Revealed spans** are exempt from these rules.

## Table grid

- `TableGridView` is a text attachment view: one cell is one small text view
  using the same inline styling (`MarkdownLayout` applied to the cell text).
- Tab and Shift-Tab move between cells, and Return moves down. Commands add
  and delete rows and columns, and set column alignment.
- Each cell edit becomes a patch to that row's source:
  - `|` is escaped as `\|`.
  - The edit goes through the document's single edit path, so one undo stack
    covers cells.
  - Column padding is left alone on ordinary typing, to keep git diffs small.
    The table is reformatted only on structural changes.
- Spelling works per cell.
- ⌘' on the table reveals the raw source as an escape hatch.

## Embedded blocks

- `BlockRenderer` keeps one shared offscreen `WKWebView` that loads the
  existing web layer (KaTeX, Mermaid, cmark HTML for HTML blocks).
- Each block is rendered to an image. The cache key is the source text plus
  the theme, and the output is the image plus its size.
- Blocks are rendered lazily as they scroll into view, using a placeholder of
  the cached or estimated height.
- A theme change invalidates the cache.
- Typing elsewhere never re-renders a block.

## Reader features

- **Outline:** built from `MarkdownLayout` headings, with the existing slug
  algorithm, so `#heading` links resolve as they do today. It updates live.
- **Links:** a click in read-only mode, or ⌘-click while editing, follows the
  link. `#…` scrolls to the heading; anything else opens externally.
- **Reading position and bookmarks:**
  - Stored as the character offset of the first visible line, which survives
    edits and resizes.
  - Existing `readingPosition.<path>` / `bookmark.<path>` entries hold a
    scroll fraction. They are read once as a fraction, then rewritten as an
    offset.
  - The percentage indicator stays.
- **Find:** the native find bar (`NSTextFinder`). It matches visible text,
  ignoring hidden markup.
- **Settings:**
  - Body and mono font, size, measure, full width, and light/dark/auto map to
    native attributes and apply live.
  - The paper & ink palette is defined as native colors.
  - `customCSSPath` is removed on macOS.
- **Print and Save as PDF:** the existing cmark/web pipeline, fed the current
  text, including unsaved edits.

## Saving and external changes

- **⌘S writes atomically,** and the window shows the edited dot.
  `WindowCloseGuard` stays.
- **Own-save echoes** are recognized, as today, and ignored.
- **External change with no unsaved edits:** adopt the disk text in place,
  keeping the caret and scroll position by mapping offsets through the
  change.
- **External change with unsaved edits:** `ThreeWayMerge(base: lastSaved,
  mine: buffer, theirs: disk)`.
  - The diff runs line by line, and word by word within lines that both sides
    changed.
  - Changes that don't overlap combine silently. The result is applied as one
    edit, and the caret and scroll are mapped through it.
  - Overlapping changes become `{~~mine~>theirs~~}[^rv-xxxx]` with a thread
    entry `@tvmv <date> suggestion: Conflicting change on disk`. They are
    resolved like any other suggestion. A conflict that spans several blocks
    becomes one anchor per block sharing the id.
  - The base becomes the disk text, and the buffer stays dirty.
- **The external-change banner is removed on macOS.**

## Components

All of these live in `TVMVCore` (pure, unit-tested) unless noted:

- **`MarkdownLayout`**
  - Input: text plus an edited range.
  - Output, per affected block: style runs, hidden ranges, reveal units,
    collapsed lines, attachment regions (tables, embedded blocks, images),
    and outline entries.
  - Backed by cmark-gfm. Inline positions are recomputed from block text
    where cmark's are wrong.
- **`EditRules`**: caret snap, delete retarget, prefix removal, list
  continuation, and the wrap shortcuts.
- **`ThreeWayMerge`**: merge, conflict ranges, and offset mapping.
- **App target:**
  - `DocumentTextView`: the `NSTextView` subclass with the layout-manager
    delegate, reveal state, attachments, and a drawing hook for code blocks
    and rules.
  - `TableGridView` and `BlockRenderer`.
  - `ViewerWindow` hosts `DocumentTextView` on macOS.
- **`ViewerModel`:**
  - The web-reader and CodeMirror paths become iOS/Linux-only.
  - The editor-pane settings (`editorPaneWidth`, `editorFont`,
    `editorFontSize`) leave the macOS settings UI.

## Performance targets

Checked by XCTest performance tests on 1 MB and 5 MB fixtures:

- A keystroke (re-parse affected blocks, restyle, glyph invalidation of that
  range) takes under 16 ms at 1 MB.
- Open to first paint takes under 300 ms at 1 MB, with embedded blocks lazy.
- No full-document work on a keystroke, a caret move, or a reveal toggle.

## Testing

- **Unit tests** for `MarkdownLayout`, `EditRules` and `ThreeWayMerge`.
- **A golden corpus** over `Fixtures/` and new fixtures: Markdown in, expected
  hidden ranges, style runs and reveal units out. It includes cmark's position
  edge cases (hard breaks, entities, code spans).
- **Merge property tests:** random local edits against random disk edits.
  - No text from either side is lost.
  - Review anchors stay well-formed.
  - Merging is idempotent when theirs equals base.
- **UI tests:**
  - Double-click reveal and leaving a revealed span.
  - ⌘E.
  - Table cell edit and Tab.
  - Checkbox toggle while read-only.
- **Manual pass:**
  - IME (Japanese and Chinese) inside emphasis.
  - Dictation and Writing Tools.
  - VoiceOver reading order with hidden markup.

## Build order

1. `MarkdownLayout` and `EditRules`, plus `DocumentTextView`, read-only and
   then ⌘E editing. This is spike parity, done properly.
2. Reader features: outline, links, reading position and bookmarks, find,
   settings, and print.
3. Lists, quotes, checkboxes and images.
4. `BlockRenderer` (math, Mermaid, HTML, front matter).
5. `TableGridView`.
6. `ThreeWayMerge` and external-change handling. The conflict-as-suggestion
   step depends on the review-comments core.

## Risks

- **Caret behavior around hidden ranges:**
  - Shift-selection across a hidden run, word motion, and double-click word
    selection on formatted text are not yet proven.
  - Mitigation: `EditRules` covers the selection-extension cases, plus an
    early manual pass.
- **IME and VoiceOver with null glyphs:** these are untested. Do the manual
  pass right after build step 1.
- **Offscreen WebKit cost:** measure memory and latency per Mermaid diagram on
  a diagram-heavy fixture during step 4.
- **Table grid complexity:** it is the largest custom component. The raw-source
  reveal remains the fallback.
- **TextKit 1 longevity:** AppKit fully supports it today. If it is ever
  deprecated, hiding moves to custom TextKit 2 layout fragments, which is a
  contained change inside `DocumentTextView`.

## Deferred

- Autosave.
- Styling customization (replacing custom CSS).
- Native editors on iOS and Linux.
- Hiding review markup in print.
