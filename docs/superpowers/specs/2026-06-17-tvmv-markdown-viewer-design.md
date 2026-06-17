# tvmv — Native Markdown Viewer (Design)

**Date:** 2026-06-17
**Status:** Approved design, pending spec review

## 1. Purpose

A native macOS application that opens a Markdown document in a real window,
quickly and with no fuss. It renders Markdown the way GitHub does, supports
text selection and copy, but does **not** edit. Fonts are overridable, defaulting
to Source Serif 4.

It is conceptually inspired by QLMarkdown but is a windowed app (not a Quick Look
extension), and reuses only the underlying rendering *engine* (cmark-gfm), not
QLMarkdown's GPL-licensed code.

## 2. Goals

- Open `.md` files in their own windows: Finder double-click, drag-drop,
  File > Open, Open Recent, set-as-default-handler.
- Open from the terminal: `tvmv file.md` (one window per file; reuses a running
  instance).
- Render GitHub-Flavored Markdown faithfully: headings, emphasis, lists, links,
  blockquotes, inline code, tables, task lists, strikethrough, autolinks, images.
- Syntax-highlighted fenced code blocks.
- Math: inline `$…$` and display `$$…$$` via KaTeX.
- Diagrams: ```` ```mermaid ```` fenced blocks via Mermaid.
- Native text selection and copy.
- Override typography via a real Settings pane: body font (default **Source
  Serif 4**), monospace font, base size, line width/measure, light/dark/auto
  theme, code-highlight theme. Settings persist and live-apply to open windows.
- Live reload when the open file changes on disk (preserves scroll position).
- Find in page (⌘F).
- Outline / table-of-contents sidebar (click a heading to jump).
- Print / export to PDF (⌘P), using the current theme and fonts.
- Fully offline: all rendering assets vendored; no network at runtime.

## 3. Non-goals (YAGNI)

- No editing or saving (read-only viewer).
- No tabs (multiple windows instead).
- No network/remote rendering.
- No Markdown dialect switches beyond GFM (no QLMarkdown `==highlight==`
  extension unless requested later).
- No theme editor beyond the typography controls listed above.
- No App Store packaging or notarization (personal/local tool).

## 4. Verified environment facts

These were confirmed empirically on 2026-06-17 and underpin the design:

- **Swift 6.3.1**, target `arm64-apple-macosx26.0`; **macOS 26.4.1**.
- **Xcode.app** is installed at `/Applications/Xcode.app`, but the active
  toolchain is still Command Line Tools (`xcode-select -p` →
  `/Library/Developer/CommandLineTools`). One-time switch (optional — SPM also
  builds under CLT): `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- **Source Serif 4** is already installed (variable font) — the default body font
  is available.
- **`apple/swift-cmark` (branch `gfm`)** is a SwiftPM package exposing library
  products `cmark-gfm` (core, includes the HTML renderer `html.c`) and
  `cmark-gfm-extensions` (table, strikethrough, autolink, tasklist). No `cmake`
  required for SPM consumers.
- **Licensing:** QLMarkdown is **GPL-3.0** (do not reuse its source). cmark-gfm
  is permissively licensed (BSD-2-Clause/MIT family). Vendored JS libraries
  (KaTeX, highlight.js, Mermaid) are MIT/BSD.

## 5. Architecture

A document-based SwiftUI app built as a SwiftPM executable and bundled into
`tvmv.app`.

- **App shell:** SwiftUI `DocumentGroup(viewing: MarkdownDocument.self)` — the
  read-only viewer variant. Provides multi-window, Open Recent, drag-drop, and
  document-type registration with minimal boilerplate and no save UI. A `Settings`
  scene provides the Preferences window. Menu `.commands` wire keyboard shortcuts.
- **Parsing:** Swift, via **cmark-gfm** → HTML body string.
- **Display:** one **`WKWebView`** per window, styled with **`github-markdown-css`**
  (light + dark) plus a thin override layer for fonts/size/measure.
- **Math / diagrams / code color:** KaTeX, Mermaid, highlight.js run as **lazy
  JavaScript** layered on top of the rendered HTML — each loaded only when the
  document actually contains math / mermaid / code.

Rationale for the split (parse in Swift, enrich in JS): cmark-gfm is GitHub's
actual parser, so the core render is GitHub-faithful and fast even on large files;
math and diagrams are JavaScript-only technologies regardless of parser (QLMarkdown
does the same), so a JS enrichment layer is unavoidable and is where they live.

## 6. Components

### `tvmvApp` (`App.swift`)
`@main` SwiftUI `App`. Declares the `DocumentGroup(viewing:)`, the `Settings`
scene, and `.commands`: Find (⌘F), Toggle Outline, Print (⌘P), Increase/Decrease
font size (⌘+/⌘−), Reload (⌘R). Owns the shared `AppSettings` and injects it into
the environment.

### `MarkdownDocument` (read-only `FileDocument`)
`static readableContentTypes` covers the markdown UTI family. `init(configuration:)`
reads the file and decodes text as **UTF-8**, falling back to **UTF-16 (BOM)** then
**ISO Latin-1** so it always shows something; records which encoding was used for an
optional notice. No write path (viewer). Document types registered in `Info.plist`
with Viewer role for extensions `md, markdown, mdown, mkd, markdn`.

### `MarkdownRenderer`
Pure function `renderHTML(_ markdown: String) -> String`. Creates a cmark-gfm
parser, registers the extensions (table, strikethrough, autolink, tasklist), parses,
and renders HTML via `cmark_render_html` with the extensions' option set. Output:
GFM body HTML, including `<pre><code class="language-…">` for fenced blocks (the
info string), and literal `$…$` / ```` ```mermaid ```` passed through for the JS
layer to handle. Small and unit-testable.

### `MarkdownWebView` (`NSViewRepresentable`)
Wraps `WKWebView`.
- A custom **`tvmv-asset://` `WKURLSchemeHandler`** serves files using a host
  segment to route: `tvmv-asset://app/…` maps to bundled web assets
  (`Contents/Resources/web`), and `tvmv-asset://doc/…` maps (path-confined) to the
  open document's own directory. This resolves relative images/links without
  `file://` sandbox quirks. `template.html` references CSS/JS via absolute
  `tvmv-asset://app/…` URLs; the injected document HTML carries a
  `<base href="tvmv-asset://doc/<abs-doc-dir>/">` so a relative `![](images/x.png)`
  resolves against the document's directory through the handler.
- Loads `template.html` **once**; subsequent content updates are pushed via
  `evaluateJavaScript("render(...)")` rather than reloading, keeping the JS
  environment warm and the update fast.
- `WKScriptMessageHandler` receives messages from JS: `outline` (heading list),
  `renderComplete`, and `error`.
- Navigation policy: external `http(s)` links are cancelled and opened in the
  default browser via `NSWorkspace`; `#anchor` links scroll in-page; no
  back/forward.

### `AppSettings` (`ObservableObject`, UserDefaults-backed)
Properties: `bodyFont` (default "Source Serif 4"), `monoFont` (default "SF Mono"
→ "Menlo" fallback), `baseFontSizePt`, `measure` (line width in `ch`, with a
full-width toggle), `theme` (`.auto` / `.light` / `.dark`), `codeTheme` (highlight.js
theme, default GitHub light/dark to match). Font choices populated from
`NSFontManager.availableFontFamilies`. Changes publish; each open `ViewerModel`
observes and pushes `applyStyle(settings)` — a JS call that updates CSS custom
properties (`--tvmv-body-font`, `--tvmv-mono-font`, `--tvmv-base-size`,
`--tvmv-measure`) and the theme class instantly, with **no re-parse**.

### `SettingsView` (SwiftUI `Form`)
The Preferences pane: body/mono font pickers with a live preview line, base-size
control, measure control + full-width toggle, theme segmented control, code-theme
picker.

### `FileWatcher`
`DispatchSource.makeFileSystemObjectSource` on the file's descriptor, watching
write/delete/rename/extend, **debounced ~150ms**. Handles atomic saves
(editors that delete+rename) by re-resolving the path and re-attaching the watch.
Drives live reload: capture scroll ratio from JS → re-read + re-render → restore
scroll ratio. Exposes a callback the `ViewerModel` subscribes to.

### Outline / TOC
Heading anchors and the outline are computed in **JavaScript** after render
(GitHub-style slug algorithm: lowercase, strip punctuation, spaces→hyphens, dedupe
with `-1`/`-2`), guaranteeing the assigned `id`s match the anchors used for
navigation. The `{level, title, anchor}` list is posted to Swift, which renders a
`NavigationSplitView` sidebar; clicking an item calls `scrollToAnchor(id)`.

### `ViewerWindow` / `ViewerModel`
Per-document window: `NavigationSplitView` with an optional outline sidebar and a
`MarkdownWebView` detail. `ViewerModel` (`ObservableObject`) holds the document
text, current outline, the `WKWebView` reference (via the representable's
coordinator), find state, and the `FileWatcher`; it observes `AppSettings`.

### Web assets (`Resources/web/`, vendored, offline)
- `template.html` — skeleton with `#content`, referencing CSS/JS via `tvmv-asset://`.
- `app.css` — `github-markdown-css` (light + dark) + override layer defining the
  CSS custom properties + print styles.
- `boot.js` — defines `render(html)`, `applyStyle(settings)`, `scrollToAnchor(id)`,
  `getScrollRatio()` / `setScrollRatio(r)`, outline extraction, and lazy
  initialization: run highlight.js only on present code blocks; run KaTeX
  auto-render (`renderMathInElement`, ignoring `pre`/`code`/`script`/`style`) only
  if `$`/`$$` delimiters are present; convert ```` ```mermaid ```` blocks to
  `<div class="mermaid">` and run `mermaid.run()` only if present. Posts
  `outline` / `renderComplete` / `error`.
- `vendor/` — pinned KaTeX (js + css + fonts + auto-render), highlight.js
  (+ GitHub theme css), Mermaid. `THIRD-PARTY-LICENSES.md` records versions and
  licenses.

## 7. Data flow

1. Open via Finder double-click / `tvmv file.md` (→ `open -a`) / Open dialog /
   drag-drop.
2. `DocumentGroup` creates `MarkdownDocument`; text is read + decoded.
3. `ViewerWindow` appears; `MarkdownWebView` loads `template.html` once.
4. Swift calls `MarkdownRenderer.renderHTML(text)` → body HTML →
   `evaluateJavaScript("render(bodyHTML)")`.
5. `boot.js` injects HTML, assigns heading anchors, posts the outline, and lazily
   runs highlight.js / KaTeX / Mermaid as needed; posts `renderComplete`.
6. Settings change or system appearance change → `applyStyle()` updates CSS vars /
   theme class instantly.
7. File change (watcher) → capture scroll ratio → re-render → restore scroll.
8. TOC click → `scrollToAnchor`; ⌘F → `WKWebView.find`; ⌘P →
   `webView.printOperation` (Save-as-PDF available in the print panel).

## 8. Error handling

- **Unreadable file:** `MarkdownDocument` init throws → `DocumentGroup` shows a
  failure; decoding never crashes (fallback chain).
- **Encoding:** UTF-8 → UTF-16 (BOM) → ISO Latin-1, with an optional "decoded as …"
  notice.
- **Math errors:** KaTeX `throwOnError: false` renders the offending source in red
  inline.
- **Diagram errors:** each Mermaid block is rendered independently; a failure shows
  an inline error box for that block only and never breaks the document.
- **File deleted/moved while open:** a subtle "file no longer on disk" banner; the
  last render is kept; the watcher re-attaches if the file reappears (atomic save).
- **Missing image:** degrades to the browser's broken-image; harmless.
- **Large files:** render normally but skip auto-highlighting of very large code
  blocks; the JS enrichment is lazy and bounded so the UI stays responsive.

## 9. Build & distribution

- **Package:** SwiftPM executable target `tvmv` depending on `cmark-gfm` and
  `cmark-gfm-extensions` (from `apple/swift-cmark`, branch `gfm`); web assets
  bundled as resources.
- **Toolchain:** optional one-time
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`; build with
  `swift build -c release`.
- **Bundling:** `build/bundle.fish` assembles `tvmv.app`
  (`Contents/MacOS/tvmv`, `Info.plist`, `Resources/web/…`, app icon), **ad-hoc
  signs** (`codesign -s - --deep`), installs to `~/Applications`, registers
  document types (`lsregister`), and installs the CLI shim.
- **Info.plist:** `CFBundleIdentifier`, `CFBundleName=tvmv`,
  `LSMinimumSystemVersion`, `NSPrincipalClass=NSApplication`,
  `NSHighResolutionCapable=true`, `CFBundleDocumentTypes` (Viewer role, markdown
  UTIs), `UTImportedTypeDeclarations` for the markdown extensions,
  `LSApplicationCategoryType=public.app-category.utilities`.
- **CLI shim** (`tvmv`, installed on `PATH`): resolves each argument to an absolute
  path, then `open -a "…/tvmv.app" -- "$@"`. `open -a` reuses a running instance
  and routes each file through the document controller → one window per file.
- **Offline assets:** vendored JS committed to the repo; `build/vendor.fish`
  (re)downloads pinned versions.
- **No notarization** (local tool); ad-hoc signing minimizes Gatekeeper friction
  (first launch may need right-click → Open).

### Project layout (anticipated)

```
tvmv/
  Package.swift
  Sources/tvmv/
    App.swift
    MarkdownDocument.swift
    MarkdownRenderer.swift
    MarkdownWebView.swift
    ViewerWindow.swift
    ViewerModel.swift
    AppSettings.swift
    SettingsView.swift
    FileWatcher.swift
    Outline.swift
    Resources/web/{template.html, app.css, boot.js, vendor/…}
  build/{bundle.fish, vendor.fish, Info.plist, tvmv (CLI shim)}
  Fixtures/showcase.md
  Tests/tvmvTests/…
  THIRD-PARTY-LICENSES.md
```

## 10. Testing

- **Swift unit tests:** `MarkdownRenderer` output (headings, tables, task lists,
  strikethrough, autolinks, fenced-code language class, mermaid/math passthrough);
  encoding fallback; CLI path-absolutization; `FileWatcher` debounce (rapid writes
  → single callback) using temp files; `AppSettings` ↔ UserDefaults round-trip.
- **Render fidelity:** a `Fixtures/showcase.md` exercising every feature (all
  heading levels, nested lists, tables, task lists, blockquotes, inline + fenced
  code in several languages, inline `$x^2$` + display `$$…$$` math, a Mermaid
  flowchart, images, links, strikethrough, autolinks) for visual QA and snapshot
  seeding.
- **JS logic (optional):** Node-run tests for `boot.js` pure functions (slug
  generation, math/mermaid detection).
- **Smoke (optional):** launch with the showcase, assert `renderComplete` posts and
  the outline populates.

## 11. Open questions / future

- App display name is `tvmv` (from the working directory); rename is trivial if
  desired.
- A `==highlight==` extension and additional Mermaid/KaTeX configuration can be
  added later without architectural change.
