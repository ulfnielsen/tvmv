# Native Find and Home Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make macOS native Find highlight rendered table text and Home scroll the document to the top.

**Architecture:** Keep the AppKit Find bar; project document and visible table-cell text into the coordinates of one `NSTextFinderClient` and map feedback back to its views. Route bare Home through the outer text view’s scroll view without moving the selection.

**Tech Stack:** Swift, AppKit, TextKit 1, XCTest.

**Spec:** [Native Find and Home](../specs/2026-11-18-native-find-and-home-design.md)

## Global Constraints

- Keep the AppKit Find bar, document search order, Markdown storage, and table editing.
- Home scrolls the outer document without changing selection, focus, or edits.
- Leave modified Home shortcuts and other platforms alone.

## Review Focus

- Search across hidden inline formatting within a cell, not across cells.
- Hidden table delimiters must not become matches; explicitly revealed source remains searchable.
- Search navigation must continue from a cell into the surrounding document and wrap.
- Edits or grid rebuilds must not leave stale cell references or offsets.
- Home from a selected table cell must scroll the outer view without changing selection.

---

### Task 1: Home navigation

**Files:** `Sources/tvmv/DocumentTextView.swift`, `Tests/tvmvTests/NativeDocumentViewTests.swift`.

**Interfaces:** Existing `keyDown(with:)`, `scrollToBeginningOfDocument(_:)`, `cellHost?.document`, and outer `NSScrollView`.

- [ ] Write `testHomeScrollsToTopWithoutChangingSelection`: host a long document with a table near its midpoint; send a real Home event (`NSHomeFunctionKey`, key code 115) to the document and then to the focused cell. In both cases assert the clip starts scrolled down before Home (`bounds.minY > 0`) and is at zero afterward, and that selection and first responder are unchanged.
- [ ] Run `swift test --filter NativeDocumentViewTests/testHomeScrollsToTopWithoutChangingSelection` and identify the failed scroll or selection assertion.
- [ ] Make the bare Home command scroll the outer clip to its top, including when invoked by a cell. Prefer the responder command if the event reaches it; if it does not, catch the bare physical key in `keyDown(with:)` and leave modified events to AppKit.
- [ ] Rerun the filtered test and verify zero failures.

### Task 2: Rendered table Find

**Files:** New `Sources/tvmv/DocumentFindClient.swift`; modify `Sources/tvmv/DocumentTextView.swift`; test in `Tests/tvmvTests/NativeDocumentViewTests.swift` or a dedicated `DocumentFindTests.swift`.

**Interfaces:** `NSTextFinderClient` supplies searchable strings, selection, scroll and geometry; `DocumentTextView.performTextFinderAction(_:)` routes the existing Find commands; `layout.tables`, `tableGrids`, and `.tvmvHidden` describe the source and rendered views.

- [ ] Write AppKit regression cases: find `alpha beta` in `alpha **beta**` and assert the visible cell selects local UTF-16 range `{0, 12}`; verify a next match below the table and wrap back. Assert hidden `|` and queries that span cells do not navigate to a match, revealed table source is searchable, and a change to a cell is reflected in subsequent navigation. Exercise a Find action sent from a cell and verify it uses the outer bar.
- [ ] Run `swift test --filter DocumentFindTests` (or the native view test class if cases are placed there) before implementation; expect rendered cell result/selection and routing assertions to fail, not a test setup error.
- [ ] Implement `DocumentFindClient` as the native finder client. Use segments in document order, splitting around rendered tables and mapping each cell’s visible UTF-16 coordinates back to its local storage. Declare a search boundary between cells. Supply the actual cell view, glyph rectangles, selection, and scroll behavior for a cell hit. Preserve the ordinary document and revealed-table paths. Keep mappings current across layout/content changes and notify the finder before its searchable text changes. Keep edit/replace operations mapped to source and avoid silently editing table delimiters.
- [ ] Rerun Find and Home tests; inspect the diff for changes to other responder actions or table editing.
- [ ] Run the full `swift test` suite and `git diff --check`; report actual counts and any failures.
