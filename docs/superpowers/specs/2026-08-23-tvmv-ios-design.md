# TVMV for iOS — design

Date: 2026-08-23
Status: approved in discussion; this document is the written record.

## Goal

Ship TVMV as a universal iOS App Store app (iPad-first, iPhone supported):
GitHub-Flavored Markdown viewing **and** editing with the same rendering
pipeline, "paper & ink" theme, and editor as the Mac app. The Mac app and its
Developer ID + `bundle.fish` pipeline stay exactly as they are.

Decisions already made:

- **App Store product**, universal (iPad + iPhone), viewer + editor.
- **iOS 26.0 minimum** deployment target.
- **Create + open**: the Files browser offers "Create Document" as well as
  opening existing files (iCloud Drive, Working Copy, any file provider).
- **Code sharing**: the WebKit bridge layer and view model are promoted into
  `TVMVCore` (approach A) rather than forked. One copy of the editing state
  machine, the patch bridge, and the settings model.
- Mac distribution is Developer ID only — no Mac App Store variant. The App
  Store presence is the iOS app (sub-project 3 handles submission).

## Architecture

### Targets and layout

```
Package.swift            platforms: [.macOS(.v14), .iOS("26.0")]
Sources/TVMVCore/        shared: renderer, text codec, patcher, bridges,
                         ViewerModel, AppSettings, web assets (unchanged)
Sources/tvmv/            Mac shell: NSViewRepresentables, windows, menus,
                         WindowCloseGuard, SettingsView (unchanged behavior)
ios/project.yml          XcodeGen spec (committed)
ios/TVMV.xcodeproj       generated, gitignored
ios/Sources/             iOS shell: app entry, document, screens,
                         UIViewRepresentables
build/ios.fish           xcodegen + xcodebuild + simulator install/launch
```

- Bundle ID `dk.dyregod.tvmv.ios` (Mac is `dk.dyregod.tvmv`).
- The iOS app consumes `TVMVCore` as a local package dependency; the SwiftPM
  resource bundle (`web/` assets) ships inside the iOS app automatically.

### Core promotion (refactor of existing code)

Moves from `Sources/tvmv/` into `Sources/TVMVCore/`:

| Component | Platform seams |
|---|---|
| `ViewerModel` | chrome color becomes a plain RGBA value (no NSColor) |
| `AppSettings` | theme resolution: `NSApp.effectiveAppearance` on macOS, `UITraitCollection` on iOS (`#if os(...)`) |
| `MarkdownWebController` + preview coordinator | external-link opening injected as a closure (`NSWorkspace` / `UIApplication.open`); `NSPrintOperation` under `#if os(macOS)` |
| `EditorBridge` + editor coordinator, `EditorPosition` | none — already platform-neutral WKWebView code |

Stays Mac-side: `MarkdownWebView`/`CodeMirrorEditorPane` representable
wrappers (become thin shells over shared factories), `ViewerWindow`,
`WindowCloseGuard`, `ViewerCommands`, `SettingsView`, `App`.

Acceptance for this refactor: Mac app builds, all tests pass, `bundle.fish`
produces a working app, and the edit → type → ⌘S smoke round-trips.

### iOS document model

`MarkdownEditableDocument: FileDocument` (iOS target):

- `init(configuration:)` decodes via `MarkdownText.decode` (encoding + line
  ending recorded, text LF-normalized — same contract as Mac).
- `fileWrapper(configuration:)` encodes via `MarkdownText.encode`, restoring
  the original encoding and newline style byte-exactly.
- `DocumentGroup(newDocument:)` supplies the document browser, Create
  Document, file-provider access, autosave, and external-change handling.

Consequences: on iOS the model's `save()`, `FileWatcher`, and the
external-change banner are simply not wired — the platform document
machinery owns persistence and conflicts. Edits flow ViewerModel →
document binding → autosave.

### iOS UI

- **iPad regular width**: `NavigationSplitView`; sidebar = outline list;
  detail = preview, or editor + preview side by side while editing.
- **iPhone / compact**: Preview/Edit toggle in the toolbar; outline as a
  sheet; one pane at a time.
- **Find**: same overlay bar and `window.tvmv.find` contract (debounced,
  generation-ordered, capped — all shared).
- **Share as PDF**: `WKWebView.createPDF` → share sheet (replaces Mac
  print/Save-as-PDF).
- **Settings sheet**: body/mono font, size, measure, theme. Custom CSS
  stays Mac-only for now.
- Web assets (boot.js, editor.js, CodeMirror, highlight.js, KaTeX, Mermaid)
  ship unchanged; the bridge contracts are identical.

## Error handling

- Render/JS errors surface through the existing `onError` callback into a
  banner, same as Mac (suppressed while editing, as on Mac).
- Document read failures surface through the document browser's own error
  presentation.
- Patch-bridge incoherence falls back to a full `getText()` resync (shared
  behavior, already tested).

## Testing & verification

- Shared logic keeps its SwiftPM tests (70 tests: patcher, model, watcher,
  renderer, settings) — these now cover the promoted code.
- `build/ios.fish`: regenerate project, build for iPad simulator, install,
  launch; smoke = open a seeded sample document, screenshot rendered output.
- Performance gates (`TVMV_PERF=1`) unchanged; the native pipeline is shared.

## Milestones

1. **Core promotion** — refactor, Mac behavior unchanged (acceptance above).
2. **Scaffold** — XcodeGen project builds; empty DocumentGroup app launches
   in the iPad simulator.
3. **Preview path** — open document → rendered page, outline sidebar, find.
4. **Editing path** — editor pane, patch bridge, autosave round-trip.
5. **Compact + polish** — iPhone layouts, share-as-PDF, settings sheet.

## Out of scope (later sub-projects)

- App Store submission: icons, listing, TestFlight, review (sub-project 3).
- iOS QuickLook / Files thumbnail extension.
- Custom CSS override and file watching on iOS.
- Keyboard accessory / hardware-keyboard refinements beyond CodeMirror
  defaults.
