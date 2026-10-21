# Native single-surface editor (Linux) — design

**Date:** 2026-10-21
**Status:** Draft, pending user review
**Base spec:** [2026-10-14-native-editor-design.md](2026-10-14-native-editor-design.md).
This document lists only where Linux differs. Anything not mentioned here
works as the base spec says.
**Also applies:** [2026-10-14-review-comments-design.md](2026-10-14-review-comments-design.md)

## Goal

Bring the macOS v1.1.0 editor to Linux: one GTK view that is both the reader
and the editor, with markup hidden, review comments in the margin, and native
spelling. It replaces the WebKitGTK preview and the CodeMirror pane in the
main window. The Markdown file stays the single source of truth, and nothing
is re-serialized.

The target is what macOS shipped, not the whole base spec. Embedded blocks
(math, Mermaid, HTML, front matter) and the three-way merge are not built on
macOS yet, so they are deferred here too. Until then those blocks show as
source, styled as code, and external changes keep today's banner.

## Decisions

1. **Same interaction model as macOS:**
   - A document opens read-only, and **Ctrl+E** enables typing in the same
     view.
   - Markup is always hidden. **Ctrl+'** reveals one span, and
     **Ctrl+Alt+M** (Show Markdown) toggles all markup.
   - **Ctrl+B / Ctrl+I / Ctrl+K** wrap a selection. **Ctrl+Shift+M** adds a
     comment and **Ctrl+Shift+E** suggests an edit.
   - Ctrl+E no longer opens a pane. In a `--peek` window it still promotes
     to a real window, now with editing on.
2. **Text stack: GtkTextView now, GtkSourceView 5 with spelling.**
   `TvmvView` subclasses `gtk::TextView`. Step 3 switches the parent to
   `sourceview5::View` over a `sourceview5::Buffer`, which libspelling
   requires; neither library is installed on the development machine yet.
   There is no language definition and no syntax highlighting: TVMV's tags
   do all the styling.
3. **Hiding uses tags with `invisible = true`.** GTK drops invisible text from
   layout. Raw GTK already skips it for arrow keys, word motion and
   Shift-selection, so the caret rules are fewer than on macOS (see Editing
   rules).
4. **Parsing uses the vendored cmark-gfm** that `render.rs` already links.
   The layout walk is a Rust port of `MarkdownLayoutParser`, held to the
   Swift output by a golden corpus (see Testing).
   - Edits always run a full re-parse plus a layout diff, as on macOS.
   - The parse runs on a worker thread above 64 KB, and the latest result
     wins.
5. **Opening is lazy.** The first screen is tagged synchronously. The rest is
   tagged in idle chunks outward from the viewport. This is the main change
   from macOS, forced by GTK's tag cost (see Evidence).
6. **Tables and images are child anchors** in the buffer: a grid widget for
   tables, a paintable for images. An offset map converts between buffer
   offsets and source offsets (see Offsets).
7. **Custom CSS is dropped from the main window.** Settings keeps it for
   print and `--html`, which still use the web pipeline. Peek and thumbnails
   are unchanged.
8. **Soft line breaks are spaces in the buffer.** A GTK paragraph ends at
   every newline, and no tag changes that, so a hard-wrapped paragraph
   would not reflow. The buffer holds a space wherever the layout has a
   soft break, and the source mirror keeps the newline. Both are one byte,
   so offsets agree.
   - The buffer is therefore not the file. Saving writes the mirror, and
     copying copies the source.
   - When a newline becomes or stops being a soft break, the view swaps the
     character in the buffer. Swaps are neither mirrored nor undoable.
9. **Undo is the view's own,** in source offsets (`native/undo.rs`), and
   GTK's is off. GTK's undo would record the swaps above. One stack is also
   the single edit path that table cells and review actions need. Typing
   coalesces by word, and runs of deletes coalesce.

## Evidence (throwaway spike, 2026-10-20)

A single-file GTK4 app of about 1,300 lines, kept outside the repo, ran its
checks headless under Broadway. It used plain GtkTextView and pulldown-cmark.

- **Caret:**
  - With no handlers at all, 25 visible characters took 25 arrow presses and
    the caret never rested inside markup. Word motion and Shift-selection
    behaved the same way.
  - Raw GTK got five cases wrong:
    - Backspace and Delete removed a hidden `*`.
    - The down arrow could land on a collapsed closing-fence line.
    - Home and caret placement could land before a hidden `## ` or `- `.
  - About 100 lines of handlers fixed all of them: a `mark-set` snap and
    overrides of `backspace` and `delete-from-cursor`.
  - Tag changes never entered the undo history.
- **Performance** (median of 30 keystrokes, middle of the document):

  | | 64 KB | 1 MB | 5 MB |
  |---|---|---|---|
  | diff + restyle changed range | 0.1 ms | 0.4 ms | 2.1 ms |
  | full re-parse (pulldown) | 1 ms | 15 ms | 78 ms |
  | tag everything on open | 13 ms | 207 ms | 1.07 s |
  | first paint, everything tagged | 17 ms | 140 ms | 665 ms |
  | first paint, first screen tagged | 9 ms | 10 ms | 13 ms |
  | memory cost of the tags (fresh process) | — | +19 MB | +91 MB |

- **Tables:**
  - `get_text(include_hidden = true)` leaves out the U+FFFC of child anchors
    and paintables, so the buffer text equals the file byte for byte.
  - A cell edit patched the hidden pipe-table source through the main buffer
    as one undo step, with `|` escaped.
  - Undo did not re-sync the cell views.
- **Drawing:** bullets drawn in `snapshot_layer` worked once limited to the
  visible lines. Calling `iter_location` on offscreen lines forces layout.
- **Not tested:** real frame timings (Broadway sends one frame), IME, screen
  readers, libspelling, HiDPI, scrolling at 5 MB, and GtkSourceView in place
  of GtkTextView.

## Findings from step 1 (2026-10-21)

These are GTK 4.14 behaviors the view depends on, each found while building
step 1:

- **`iter_location` is wrong after hidden text.** It measures invisible
  characters as if they were shown: each one shifts the reported x by one
  character. `cursor_locations` gives the drawn position, so all drawing
  uses it.
- **`iter_at_location` returns nothing past a line's end,** for example at
  the right edge of the window. The visible range comes from `line_at_y`.
  The first version fell back to the whole document there. It then asked
  GTK about every list item on every frame, which forced a layout of the
  whole document: 3 s per frame at 5 MB.
- **`remove_all_tags` searches for the next toggle of any tag,** and in an
  unstyled stretch of buffer that search runs to the end. So the first pass
  over a never-styled range does not clear first. Otherwise lazy styling
  was quadratic: 36 s at 5 MB.
- **Priorities:** lazy styling runs at idle priority 123. That is after
  redraws (120) and before GTK's background line validation (125), so no
  line is laid out unstyled and then again.
- **A transparent foreground draws opaque.** "Clear" text (a point
  comment's carrier, the `>` gap of a substitution) uses the paper color.
- **The default text color comes from the `textview` CSS node,** not
  `textview text`.
- **A large document's buffer starts with its first screen only.** The
  first 32 KB, cut at a blank line, is parsed and styled synchronously. The
  whole text goes into the buffer when its full parse lands. Filling a
  buffer costs about 17 ms per MB.

Measured by `tvmv --self-check` (headless, Broadway):

| | 64 KB | 1 MB | 5 MB |
|---|---|---|---|
| first screen shown, styled | 12 ms | 13 ms | 20 ms |
| whole parse landed | 31 ms | 132 ms | 642 ms |
| everything styled | 39 ms | 414 ms | 2.2 s |
| GTK line validation done | 83 ms | 1.0 s | 5.2 s |
| keystroke + installing its parse (median) | 0.6 ms | 1.2 ms | 8.0 ms |

## Offsets

There are three coordinate systems:

- **Source offsets** are UTF-8 byte offsets into the file. The Rust core
  (`layout`, `edit_rules`, `review`) uses only these.
- **Buffer offsets** are GTK character offsets. They count Unicode scalars
  plus one U+FFFC per child anchor or paintable.
- **Swift offsets** are UTF-16. They appear only in the golden fixtures and
  are converted by the test harness.

`SourceText` (`offsets.rs`) mirrors the source and converts between the
first two. It holds (byte, character) checkpoints about 256 bytes apart,
plus the sorted anchor positions. A lookup is a binary search plus a count
within one gap. An edit shifts the checkpoints after it and re-spaces the
gap it landed in. Saving writes the mirror (see decision 8).

## What renders how

The same as the base spec's table, except for these rows:

| Construct | Display | Notes |
|---|---|---|
| Bullets, numbers, checkboxes, quote rules, thematic breaks, code-block backgrounds | Drawn in `TvmvView::snapshot_layer` (below text) | Visible lines only |
| Fence lines | Invisible, so they take no height | Caret rule below |
| Images | `insert_paintable` with a `gdk::Texture` from the local file | Counted in `SourceText` |
| Tables | `TableGrid` on a child anchor | Below |
| Math, Mermaid, HTML blocks, front matter | Source, in the code style | Embedded rendering deferred |
| Review cards | `TvmvView::add_overlay` in the right margin | Below |

## Editing rules

`edit_rules.rs` is a port of `EditRules.swift`, minus the rules GTK already
covers.

- **Kept:**
  - Delete retarget, and removal of a whole line prefix on Backspace.
  - The start-of-paragraph snap: the caret never rests before a hidden
    heading, list or quote prefix. This covers Home, clicks, and arrival from
    the previous line.
  - Collapsed fence lines pass in the direction of travel. Collapsed review
    thread definitions push the caret back out.
  - Inner edges, list continuation, and the wrap shortcuts.
- **Not needed:** snapping during plain movement and the selection-extension
  cases. GTK already handles them.
- **How they are wired:** `mark-set` on the insert mark applies the snap.
  `backspace` and `delete-from-cursor` are overridden in the subclass, and
  everything else goes through a key controller in the capture phase.

## Lazy tagging and tag memory

- **On open:**
  - Parse off-thread, then `set_text`, then tag the lines visible at the
    restored reading position.
  - Then tag outward in idle chunks of about 2 ms each, until done.
  - An edit cancels any pending chunk that it overlaps.
- **Tag memory** was measured on 2026-10-21, one process per variant, over
  plain text in a presented view:

  | 5 MB file | toggles | RSS over plain text |
  |---|---|---|
  | `invisible` tags only | 0.76 M | +64 MB |
  | invisible everywhere, styles near the viewport | 0.76 M | +66 MB |
  | everything | 1.19 M | +91 MB |

  That is about 76 bytes per toggle. The spike's earlier 360 MB figure was an
  artifact of measuring after other variants in the same process. Every tag
  is therefore applied to the whole document, with no viewport windowing,
  since windowing would save only 25 MB for a lot of complexity.
- **Shared tag table:** each style is one named `TextTag` created once per
  theme. Tags are never created per run.

## Spelling

- Spelling uses **libspelling** (`SpellingTextBufferAdapter` on the source
  buffer), with the language from the locale and a menu to change it.
- **Exempt ranges:** code, URLs, review ids and labels, and revealed markup.
  libspelling skips text covered by the source buffer's `no-spell-check`
  context class. Whether a plain `TextTag` can do the same is not yet
  known. If it can't, TVMV registers a minimal language definition that only
  emits that class over the exempt ranges.
- There is no grammar checking. GTK has no system grammar service.

## Table grid

- `TableGrid` is a `gtk::Grid` of small `sourceview5::View` cells on a child
  anchor. The source table stays in the buffer and is hidden.
- Cell edits patch the hidden source through the main buffer's single edit
  path, as the spike did. Tab, Shift+Tab and Return move between cells. Row,
  column and alignment commands are the same as on macOS.
- **Re-sync:** after every buffer change that touches the table's source
  range, including undo and redo, the cells are rebuilt from `TableSource`.
  The cell with focus keeps its caret.
- A gap overlay (a widget over a blank, reserved region, with no U+FFFC) is
  the fallback if anchors misbehave with IME or screen readers. It was not
  tested: Broadway never re-ran layout.

## Review comments

The core is ported from Swift: `ReviewMarkup` (done, `review.rs`),
`ReviewSpans`, `ReviewLayout` and `ReviewOperations`. The UI differs from
macOS as follows:

- **Cards** are `TvmvView::add_overlay` children placed in buffer coordinates
  inside a right margin (`set_right_margin`). They are stacked by the
  `ReviewLayout` port and moved on scroll and relayout.
- **Narrow windows** show gutter markers that open a `gtk::Popover`.
- **Creating** a comment or suggestion opens a popover at the selection.
- **The Review menu** is a section of the window's primary menu. The
  commands are the same as on macOS.

## Reader features

- **Outline:** the existing sidebar (`outline.rs`), fed from the layout's
  headings through the `HeadingSlugger` port.
- **Links:** a click while read-only, or Ctrl+click while editing. The
  cursor changes to a pointer over links.
- **Reading position and bookmarks:** `reading.json` stores fractions today
  (`position`, `bookmark`). Each fraction is read once and rewritten as a
  source offset, as on macOS. Clear Bookmark keeps the right-click popover.
- **Find:** `sourceview5::SearchContext` on the buffer, kept inside the
  existing bar in `find.rs`. It searches the source, as on macOS.
- **Settings:** fonts, size, measure, full width and light/dark/auto apply
  to the tag table live. The paper & ink colors come from the same values
  as `NativeTheme`.
- **Print and PDF:** unchanged. `print.rs` feeds the current text,
  including unsaved edits, into the web pipeline.

## Components

All in `linux/src`. Pure modules are unit-tested without GTK.

- **Pure:**
  - `layout.rs`: ports of `MarkdownLayout`, `MarkdownLayoutParser` and
    `MarkdownLayoutDiff` over the cmark AST.
  - `edit_rules.rs`, `offsets.rs` (`SourceText`), and `table_source.rs`.
  - `review.rs`, extended with `review_spans.rs`, `review_layout.rs` and
    `review_ops.rs`.
- **GTK, in `native/`:**
  - `view.rs`: `TvmvView`, the subclass. It lays out the column and draws
    below the text.
  - `document_view.rs`: the controller. It owns the source mirror, the
    parse cycle, the edit path, the edit rules, reveal, the clipboard and
    input.
  - `styler.rs`: the tags, plus `Prepared`, a layout with the range indexes
    built on the parse thread.
  - `undo.rs` (pure) and `theme.rs`.
  - `check.rs`: `tvmv --self-check` and `tvmv --native-shot`.
  - `window.rs`: the step-1 window behind `tvmv --native`, which step 2
    retires.
  - To come: `table_grid.rs` and `review_cards.rs`.
- **Removed from the main window:** `editor.rs` and the CodeMirror bridge,
  and `preview.rs` as the main view. Peek, `--html`, `--pdf` and print keep
  the web layer.
- **New dependencies:** `sourceview5` and `libspelling`, with versions
  matching gtk4 0.11. On Debian/Ubuntu these need `libgtksourceview-5-dev`
  and `libspelling-1-dev`. The Flatpak gets GtkSourceView from the GNOME
  runtime but must bundle libspelling (and enchant).

## Performance targets

Measured by `cargo bench` on 1 MB and 5 MB fixtures, plus timed checks in
the GTK harness:

- **Per keystroke,** main-thread work stays under 16 ms at 5 MB. This covers
  the edit, the diff, and restyling the changed range.
- **First paint** comes in under 50 ms at 5 MB.
- **Fully tagged** within 2 s at 5 MB, without blocking input.
- **Tag memory** stays under 100 MB at 5 MB (measured: 91 MB).

### Against the WebKit window (2026-10-21)

`tvmv --bench FILE --runs 3` opens the file in both, each in a fresh
process, on a real display (GNOME Wayland; run it under
`gnome-session-inhibit --inhibit idle`, since a locked screen paints no
frames). Medians of 3 runs on the generated 1 MB and 5 MB documents:

| | 1 MB WebKit | 1 MB native | 5 MB WebKit | 5 MB native |
|---|---|---|---|---|
| open, from process start | 1334 ms | 156 ms | 5275 ms | 180 ms |
| open, second window | 1215 ms | 42 ms | 5210 ms | 44 ms |
| fully styled | — | 478 ms | — | 2.3 s |
| after an edit | 600 ms wait + 962 ms | 84 ms | 1000 ms wait + 5150 ms | 497 ms |
| main thread per edit | 61 ms | 1.4 ms | 370 ms | 8.9 ms |
| scroll fps / worst frame | 59 / 133 ms | 60 / 32 ms | 53 / 700 ms | 60 / 17 ms |
| memory, all processes (PSS) | 882 MB | 207 MB | 2.7 GB | 816 MB |

The native view's first-launch open includes about 150 ms of process and
GTK start-up. An early run showed a 1.2 s first paint at 1 MB; that was the
probe's fault, not the view's: it attached to the frame clock from a default-
priority idle, which waits behind the lazy styler.

## Testing

- **Layout golden corpus:**
  - A Swift test, run on a Mac, writes `MarkdownLayout` as JSON for every
    file in `Fixtures/`, in UTF-16 offsets, into `Fixtures/layout/`.
  - The Rust tests load the JSON, convert its offsets, and require an exact
    match.
  - This is the only part that needs a Mac. Regenerate it whenever
    `MarkdownLayoutParser.swift` changes.
- **Ported unit tests** for `EditRules`, `TableSource` and the review core,
  mirrored assertion for assertion, as `review_render.rs` does.
- **Random-edit invariants,** as on macOS: over many random edits, the
  diffed layout equals a full parse, and nothing is hidden that isn't
  markup.
- **GTK harness:**
  - `tvmv --self-check` runs the spike's scripted checks against the real
    view: caret, delete, cells, undo re-sync, and tagging.
  - It runs under Broadway in CI for logic. Checks that need layout run
    under a headless Weston session, if that gives real frames, and
    otherwise on a desktop.
- **Manual pass on a desktop, right after step 1:**
  - IME (Japanese and Chinese) inside emphasis.
  - Orca reading order with invisible text.
  - HiDPI.
  - Scrolling at 5 MB.
  - GNOME and KDE.

## Build order

1. `layout.rs` with the golden corpus, then
   `SourceText`, `TvmvView` and `styler.rs`. Read-only first, then Ctrl+E
   editing with the edit rules. **Done 2026-10-21,** behind
   `tvmv --native FILE`. It still needs the manual pass on a desktop.
2. Reader features: outline, links, reading position, find, settings and
   print. Then remove the CodeMirror pane.
3. Lists, quotes, checkboxes, images and spelling.
4. `TableGrid`.
5. The review core port, then cards and commands.

## Risks

- **IME and Orca with invisible text** are untested. Pre-edit text inside a
  hidden-delimiter boundary is the likely failure.
- **libspelling exemptions:** see Spelling. The fallback is a minimal
  language definition.
- **Child anchors and accessibility:** a screen reader may read U+FFFC. The
  fallback is the gap overlay.
- **GtkSourceView instead of GtkTextView:** the spike used plain
  GtkTextView. Rerun its checks on the subclass first.
- **Layout parity:** the Rust parser can drift from Swift between corpus
  regenerations. The corpus is regenerated on each macOS release.

## Deferred

- Embedded blocks (math, Mermaid, HTML, front matter), following macOS.
- The three-way merge and the end of the external-change banner, following
  macOS.
- Grammar checking.
- Autosave.
- A native editor on iOS.
