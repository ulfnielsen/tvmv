# Review comments UI — plan

**Spec:** [2026-10-14-review-comments-design.md](../specs/2026-10-14-review-comments-design.md) (UI section)
**Branch:** `review-comments` (core merged from `review-comments-core`)
**Execution:** inline, TDD per task.

## Tasks

1. **Layout integration (TVMVCore).** `MarkdownLayoutParser.parse` folds
   `ReviewMarkup.parse` into the layout:
   - Drops cmark's styles, markers and other items that touch a ref or a
     thread definition. With footnotes off, cmark reads `[^rv-…]` as a link.
   - Adds hidden markers for delimiters and refs. A point ref keeps its first
     character, which carries the drawn marker. Each anchor's unit is its
     whole range, ref included.
   - Adds collapsing markers over thread definitions, whose unit is the
     thread.
   - Adds `.review(role:id:)` style runs and spell exemptions.
   - Sets `layout.review`, the parsed `Review` (nil when there is no markup).
   - Keeps the arrays ordered so `changedRange` stays exact. The property
     tests cover this.
2. **Styling (app).**
   - `DocumentStyler` styles the review roles: highlights get a yellow
     background; insertions are green and underlined; deletions are red and
     struck; substitutions show the old text struck, then the new text
     underlined, with a gap.
   - A point marker's carrier character is small and clear, and the view
     draws a bubble there.
3. **Edit path for review operations (app).**
   - `DocumentTextView.applyReview(_ patches:)` applies all the patches as one
     undoable edit, including while reading.
   - The author is `@` plus the first word of git `user.name`, lowercased.
     Without git it falls back to the account's short name.
4. **Margin cards (app).**
   - One card per thread, beside its first anchor, stacked without overlap.
   - Each card shows the kind and the entries, Accept/Reject or Resolve, and
     a Reply field.
   - Problem cards offer Delete thread or Remove markup.
   - Clicking an anchor focuses its card.
   - In a narrow window, cards become gutter markers that open a popover.
5. **Create and menu (app).**
   - ⌘⇧M (comment) and ⌘⇧E (suggest edit) open a popover at the selection.
     They work while reading too.
   - A Review menu offers Comment, Suggest Edit, Next/Previous Thread,
     Accept All and Reject All.

## Ledger
- Task 1: complete — ReviewLayoutTests 8/8 (RED: no .review style), property test with review tokens (coverage checked), perf gates pass; suite 81 app / 188 core.
- Task 2: complete — ReviewViewTests 5/5 (RED: missing theme/attr; marker pixel test RED then GREEN; tolerance loosened for color-profile shift); suite 86 app / 188 core.
- Task 3: complete — ReviewViewTests 11/11 (RED: missing API); Ruling: undo test uses view.undo(nil), the menu path (documentUndo direct while read-only can't edit) — cost if wrong: none, menu path is what users hit.
