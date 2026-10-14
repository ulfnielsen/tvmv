# Review comments and suggested edits — design

**Date:** 2026-10-14
**Status:** Draft, pending user review
**Depends on:** [2026-10-14-native-editor-design.md](2026-10-14-native-editor-design.md)

## Goal

Let humans and agents comment on parts of a Markdown document, suggest edits,
reply, and resolve, accept or reject. Everything lives **in the Markdown file
itself**:

- Any tool can read and write it, whether that's an agent with file tools,
  vim, or a GitHub PR.
- Anchors move with the text through any edit or merge.
- Comments stay visible in other Markdown readers.

TVMV is the comfortable UI on top, not a gatekeeper.

## Decisions

1. **Collaborators are humans and agents,** sharing files through git or
   otherwise. There is no TVMV-specific server or store.
2. **Inline format.** CriticMarkup anchors mark *what* a comment is about, and
   a GFM footnote holds the *thread*.
3. **Suggested edits are in scope** (insert, delete, substitute).
4. **The file holds only open threads.** Resolving a comment, or accepting or
   rejecting a suggestion, removes its markup. No history is kept. Git, if
   present, is the user's own business, and TVMV does not read it.
5. **There is no CLI.** Agents edit the markup directly; the format is
   designed so that a plain text edit is always correct.
6. **Author identity** is `@` plus the first word of git `user.name`,
   lowercased. Without git, it falls back to the account's short name.
7. **macOS first,** on the native editor.

## Format

```md
The {==cache is invalidated on every save==}[^rv-k3f9] and the index is
{~~rebuilt lazily~>rebuilt eagerly on open~~}[^rv-p2x7] from disk.
{++Autosave writes are exempt.++}[^rv-p2x7] A point comment.[^rv-z9y8]

[^rv-k3f9]: @ulf 2026-10-14: True for autosave too?
    @claude 2026-10-14: No, see the added sentence.
[^rv-p2x7]: @claude 2026-10-14 suggestion: Eager rebuild avoids the first-scroll stall.
[^rv-z9y8]: @ulf 2026-10-14: Needs a source.
```

### Anchors

| Kind | Syntax |
|---|---|
| Highlight (comment on a range) | `{==text==}[^id]` |
| Insertion | `{++text++}[^id]` |
| Deletion | `{--text--}[^id]` |
| Substitution | `{~~old~>new~~}[^id]` |
| Point comment | `[^id]` |

- **Thread reference:** every anchor is immediately followed by its
  `[^id]`. An anchor without one is shown as markup, with no thread or
  actions.
- **One block only:** an anchor stays within a single block, because
  CriticMarkup cannot span paragraphs.
  - A multi-block suggestion is one anchor per block, all sharing an id.
  - All anchors with one id are accepted or rejected together.
- **Code, math and tables:**
  - Inside code fences and math, markup is not parsed. A comment on such a
    block is a point comment on its own line directly after the block.
  - Inside a table, anchors are allowed within one cell only.

### IDs and thread definitions

- **IDs:** `rv-` followed by 4 random characters from `[a-z0-9]`. They are
  random rather than sequential so that two branches never mint the same id.
  The `rv-` prefix is reserved; other footnotes are left alone.
- **Threads are footnote definitions** at the end of the file:
  - Each entry is `@author YYYY-MM-DD[ suggestion]: text`.
  - Replies are continuation lines indented by 4 spaces in the same format.
  - Agents append replies as plain lines.

### Settling a thread

Settling is a plain text edit:

| Action | Highlight | Point | Insertion | Deletion | Substitution | Definition |
|---|---|---|---|---|---|---|
| **Resolve** (comment) | keep text | remove | — | — | — | remove |
| **Accept** | keep text | remove | keep text | remove text | keep `new` | remove |
| **Reject** | keep text | remove | remove text | keep text | keep `old` | remove |

### In other readers

- GitHub and other GFM readers show the CriticMarkup braces as literal text.
- The `[^rv-…]` references render as footnote links to the threads at the
  bottom.

## TVMVCore: `ReviewMarkup`

This module is pure Swift with no UI. Ranges are UTF-16, which matches
`TextPatcher`.

- `parse(text) -> Review`:
  - Anchors carry the id, kind, the whole range, the inner and old/new ranges,
    and the ref range.
  - Threads carry the id, the definition block range, and the entries
    (author, date, kind, body).
  - `problems` lists:
    - A thread with no anchor.
    - An anchor whose id has no thread.
    - Unbalanced delimiters.
    - Anchors with one id but mixed comment and suggestion kinds.
  - Parsing never throws: a hand-edited file degrades into reported problems.
- **Operations** each return a `[TextPatcher.Patch]`:
  - `addComment(range:body:author:date:)`
  - `addSuggestion(range:replacement:body:…)`, which emits a substitution, an
    insertion (empty range) or a deletion (empty replacement).
  - `reply(id:body:…)`
  - `resolve(id:)`
  - `accept(id:)`, `reject(id:)`, `acceptAll()`, `rejectAll()`
  - `newID(existing:)`
- **New thread placement:** `addComment` and `addSuggestion` append the
  definition at the end of the file, adding a blank line before the first
  `rv-` definition.
- **Spans:** `spans(review) -> [Span]` tells `MarkdownLayout` the hidden
  delimiters and refs, the style per kind, the spelling exemptions, and the
  collapsed definition blocks.
- **Renderer support (print, QuickLook, iOS/Linux reader):**
  - Enable `CMARK_OPT_FOOTNOTES`.
  - A pre-pass swaps each anchor for private-use sentinel characters, and a
    post-pass turns them into `<mark>`, `<ins>` and `<del>` with a
    `data-rv` id. cmark strips raw HTML, so the tags cannot go in before
    parsing.
  - In print, the `rv-` threads appear as footnotes.

## UI (native editor)

- **Inline styles:**
  - Highlights get a yellow background.
  - Insertions are green and underlined.
  - Deletions are red with strikethrough.
  - A substitution shows the old text struck, then the new text underlined,
    with a thin gap between them.
  - Point comments show as a small superscript marker.
  - Delimiters and refs are hidden. They are reveal units, so double-click or
    ⌘' shows them.
- **Thread definitions** collapse out of the flow, and the caret cannot enter
  them. ⌥⌘M shows them.
- **Margin cards:**
  - One per thread, beside its first anchor, stacked without overlap.
  - Each card shows its kind, id and entries, plus Accept/Reject
    (suggestions) or Resolve (comments), and a Reply field.
  - Clicking an anchor focuses its card.
  - In a narrow window, cards shrink to gutter markers that open a popover.
- **Create:** select text within one block, then **⌘⇧M** (comment) or **⌘⇧E**
  (suggest edit), and an inline popover opens. This works in read-only mode
  too.
- **Review menu:** Comment, Suggest Edit, Next/Previous Thread, Accept All,
  Reject All.
- **Problem cards:**
  - A thread with no anchor offers "Delete thread".
  - An anchor with no thread offers "Remove markup".
- **Undo:** every action is one undoable edit through the document's single
  edit path, and it marks the document dirty. Saving stays ⌘S.
- **External changes:** an agent replying or resolving on disk arrives through
  the editor's three-way merge. Cards update after the merge. Conflicting
  overlaps arrive as `@tvmv` suggestion threads.

## Testing

- **A golden corpus** of `before.md` + operation → `after.md` cases for every
  operation and anchor kind, including multi-anchor ids, table cells, and
  point comments after code blocks.
- **A round-trip property:** parse, then serialize with no operations, is
  byte-identical, and applying an operation then undoing it restores the
  bytes.
- **Problem detection** on malformed fixtures: orphans, dangling refs, and
  unbalanced delimiters.
- **Renderer:** HTML snapshots for anchors with footnotes enabled.
- **UI tests:** create a comment from a selection, accept, reject, resolve,
  reply, and undo.

## Deferred

- A "track changes" mode, where your own typing becomes suggestions.
- Resolved-thread history.
- Mentions and notifications.
- iOS and Linux UI. The core and the renderer support are shared from day one.
