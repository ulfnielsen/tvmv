# TVMV Linux App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship TVMV as a native Linux desktop app — fast, correctly wired into any desktop shell, with the same rendering pipeline, theme, and editor as the Mac app. No Swift is ported.

**Architecture:** Promote the web layer (`app.css`, `boot.js`, `editor.js`, vendored bundle) to `/web` as the single shared source of truth, guarded by golden HTML tests that run in both test suites. Then build a fresh Rust shell in `linux/` that implements the three seams the web layer expects — a `tvmv-asset://` URI scheme handler, a `tvmv` script-message handler, and JS evaluation — on GTK4 + WebKitGTK 6.0, linking the same cmark-gfm C library the Mac app uses. Finally integrate with every Linux preview surface that has a supported extension point.

**Tech Stack:** Rust, gtk4-rs, webkit6-rs, cmark-gfm (system C lib via FFI), XDG desktop portals, Flatpak. Web layer unchanged: CodeMirror 6, KaTeX, Mermaid, highlight.js (all vendored).

**Spec:** `docs/superpowers/specs/2026-08-26-tvmv-linux-design.md`

## Global Constraints

- **The Mac and iOS apps must not change observably.** Only Task 1 touches them at all, and only the resource path. After Task 1 the full Swift suite passes on the Mac.
- **No Swift toolchain exists on the Linux dev machine.** Tasks 1 and 2 must be gated on the Mac before they land. Tasks 3+ are fully verifiable locally.
- **The web layer is never forked.** No Linux-only CSS or JS. If the shell needs something the web layer does not expose, extend the shared `window.tvmv` API and update all three shells.
- **Collision discipline** — the three projects share a repo and nothing else:
  - Rust shell lives only in `linux/`; build output only in `linux/target/` (gitignored).
  - New build scripts are `build/linux.fish` and `build/sync-web.fish`. Existing `build/*.fish` are not modified except for the web-sync call in `bundle.fish` and `ios.fish`.
  - Settings persist to `$XDG_CONFIG_HOME/tvmv/settings.toml`. Never `UserDefaults`, never a path either Apple shell reads.
  - Desktop/D-Bus/Flatpak ID is `dk.dyregod.tvmv` — the same string as the Mac bundle ID, but in a different namespace. Do not "disambiguate" it.
  - `Package.swift` does not change. The SwiftPM resource path stays `Resources/web`.
- **Linux build deps** (Ubuntu 24.04): `libgtk-4-dev`, `libwebkitgtk-6.0-dev`, `pkg-config`. Do **not** add `libadwaita-1-dev`. The markdown engine needs no system package — it compiles the pinned `linux/vendor/swift-cmark` submodule.
- **Installing those needs sudo, which this machine does not have non-interactively.** Tasks 3–7 were built without them; Task 8 is where they become required:

  ```sh
  sudo apt install libgtk-4-dev libwebkitgtk-6.0-dev pkg-config
  ```

  Later phases add: `desktop-file-utils` + `librsvg2-bin` (Task 13), `flatpak` + `flatpak-builder` (Task 19), and `cmake` + `extra-cmake-modules` + `libkf5kio-dev` for the optional KDE plugin (Task 15).
- Test commands: `cargo test --manifest-path linux/Cargo.toml` on Linux; `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` on the Mac.
- Commit messages end with the repo's standard Claude trailer (see recent `git log`).

---

## Phase A — Shared foundation (gate on the Mac)

> Task 1 is the only work in this plan that touches the Swift build, and it is
> **not a prerequisite for Phase B**. The Rust core reads nothing from
> `Sources/`. Leave it until a Mac is available; do Phase B first.

### Task 1: Promote the web layer to `/web`

**Files:**
- Move (git mv): `Sources/TVMVCore/Resources/web/` → `web/` (74 tracked files; git records renames)
- Create: `build/sync-web.fish`
- Modify: `.gitignore`, `build/bundle.fish`, `build/ios.fish`, `README.md`
- Create: `Tests/TVMVCoreTests/WebResourceSyncTests.swift`

**Interfaces:**
- Produces: `web/` as canonical. `Sources/TVMVCore/Resources/web/` becomes a symlink or generated copy; `ResourceLocator.swift` and `Package.swift` are unchanged either way.

- [ ] **Step 1: Move the tree**

```bash
git mv Sources/TVMVCore/Resources/web web
```

`vendor.fish` resolves paths relative to its own directory, so it keeps working unchanged. Verify: `fish web/vendor.fish` still populates `web/vendor/`.

- [ ] **Step 2: Try the symlink first (on the Mac)**

```bash
ln -s ../../../web Sources/TVMVCore/Resources/web
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

If SwiftPM's `.copy()` follows the symlink and the suite passes, add
`Sources/TVMVCore/Resources/web` to `.gitignore` and **skip Step 3**. If it
does not, remove the symlink and continue.

- [ ] **Step 3: Fall back to a generated copy**

`build/sync-web.fish` mirrors `web/` into `Sources/TVMVCore/Resources/web/`
(rsync-style delete-extraneous, so a removed file in `web/` disappears from the
copy). Call it as the first step of `bundle.fish` and `ios.fish`. Gitignore the
destination.

- [ ] **Step 4: Make a stale copy fail loudly**

The README documents running `swift test` directly, which under Step 3 would
run against a missing or stale copy. `WebResourceSyncTests` asserts the copy
exists and that no file in `web/` is newer than its counterpart, failing with
the literal message `run: fish build/sync-web.fish`. Skip this test if Step 2
succeeded.

- [ ] **Step 5: Update the README** — document `web/` as canonical and the sync step if one exists.

- [ ] **Step 6: Gate on the Mac** — full suite green, `bundle.fish` produces a working app, `ios.fish` builds.

### Task 2: Shared golden HTML fixtures — **DONE**

**Files:** `Fixtures/golden/{extensions,nesting,code-math-mermaid,edge}.md`, their `.html` and `.sourcepos.html` expectations, `Fixtures/golden/README.md`

- [x] **Step 1: Fixture corpus** covering the four extensions alone and combined, non-obvious source positions in nested quotes/lists/fences, the fences the web layer post-processes, and text edge cases (setext, hard breaks, entities, Unicode, escapes, empty cells). `Fixtures/showcase.md` joins the corpus.
- [x] **Step 2: Expectations generated** from the vendored cmark-gfm — see Task 3 for why this did not need a Mac. Provenance recorded in `Fixtures/golden/README.md`.
- [x] **Step 3: `linux/tests/golden.rs`** asserts byte equality for both option modes, plus independent assertions that sourcepos actually applies, that all four extensions are attached, that unsafe HTML and `javascript:` URLs are stripped, and that an embedded NUL does not truncate.
- [ ] **Step 4: `Tests/TVMVCoreTests/GoldenRenderTests.swift`** — the Swift half, asserting against the same files. **Needs the Mac.**

### Task 3: Crate skeleton and vendored cmark-gfm — **DONE**

**Files:** `linux/Cargo.toml`, `linux/build.rs`, `linux/src/{lib,render,main}.rs`, `linux/tests/vendor_pin.rs`, `.gitmodules`, `.gitignore`

**Outcome:** `render_html(markdown, source_pos)` mirrors `MarkdownRenderer.swift` exactly. All 8 tests green.

- [x] **Step 1: Vendor swift-cmark** as a submodule at `linux/vendor/swift-cmark`, pinned to `0101bf2c` — the revision `Package.resolved` names.
- [x] **Step 2: `build.rs` compiles the C with `cc`.** swift-cmark checks in the headers CMake would generate, so no CMake and no `libcmark-gfm-dev` are needed. Sources are sorted for a reproducible compile; the re2c inputs are excluded; a missing submodule fails the build with `git submodule update --init --recursive`.
- [x] **Step 3: FFI and renderer**, with RAII guards so no early return leaks the parser or document. The length is passed explicitly rather than relying on NUL termination.
- [x] **Step 4: `vendor_pin.rs`** fails if the submodule and `Package.resolved` name different revisions — two mechanisms, one revision.

> **The engine-parity risk is closed by construction, not by testing.** Both shells compile identical C source with identical options, so they cannot diverge. The earlier plan of linking Debian's `libcmark-gfm` 0.29.0.gfm.6 — which is not necessarily the Mac's pinned point — was dropped, and with it the "stop and re-plan if goldens diverge" contingency.

### Task 4: Settings — **DONE**

**Files:** `linux/src/settings.rs`, `linux/tests/settings.rs`

**Outcome:** field set, defaults, clamps, and both JSON payloads mirror `AppSettings.swift`. 16 tests green.

- [x] **Step 1: Struct, serde defaults, atomic load/save** to `$XDG_CONFIG_HOME/tvmv/settings.toml` (temp + rename, so a crash mid-write cannot silently reset every preference). A config missing keys loads with defaults; a malformed one is reported and left on disk rather than overwritten.
- [x] **Step 2: `mono_font` default is `DejaVu Sans Mono`** — a single family, **not** a chain. `boot.js` emits `JSON.stringify(cfg.monoFont) + ", monospace"`, so a comma-separated value would be quoted whole, match nothing, and fall back to the generic silently. The earlier plan of a JetBrains Mono → Cascadia → DejaVu chain was wrong against the contract and is dropped.
- [x] **Step 3: `theme: auto` takes the system preference as a parameter** rather than querying D-Bus itself, keeping the payloads unit-testable. The portal query lives in the shell (Task 8), which is what makes it correct on KDE and XFCE too.
- [x] **Step 4: Contract tests read the shared web layer directly** — `boot.js` and `editor.js` are grepped for each `cfg.<key>` the payload emits, and the emitted key count is asserted, so a rename on either side fails here. The helper looks for `web/` first and `Sources/TVMVCore/Resources/web/` second, so the suite survives Task 1 unedited.
- [x] **Step 5:** `baseSize`/`measure` asserted to serialize as JSON *numbers* — boot.js branches on `typeof === "number"` to append `px`/`ch`, and a string would be passed through as an invalid CSS length.

### Task 5: Asset scheme handler — **DONE** (resolution half)

**Files:** `linux/src/assets.rs`, `linux/tests/assets.rs`

**Outcome:** `AssetRouter::resolve(uri)` mirrors `AssetSchemeHandler.swift`'s routing and confinement. 17 tests green. Streaming is deferred to Task 8, where WebKitGTK takes a `GInputStream` directly — the Swift side hand-rolls 1 MiB chunks only because `WKURLSchemeTask` wants `didReceive(Data)` callbacks.

- [x] **Step 1: Host routing** — `app` to the bundled web layer, `doc` to the document's directory, unknown host and no-document-yet as distinct errors.
- [x] **Step 2: MIME table.** Explicit rather than a database lookup; the served set is known. The three that must be right are `text/css`, `text/javascript`, and `font/woff2` — WebKit ignores a stylesheet and refuses a script served as `application/octet-stream`, silently. Case-insensitive, with an octet-stream fallback.
- [x] **Step 3: Traversal confinement**, covering `..`, percent-encoded `%2E%2E`, absolute paths, and a sibling directory sharing a name prefix (`/app` must not match `/app-evil`).
- [x] **Step 4: Tests for every routing and rejection case.**

> **The URI is hand-parsed, not handed to the `url` crate.** That crate normalises dot segments during parsing — percent-encoded ones included — so `..` was resolved away before this module saw it. Every traversal test passed while `confine` was unreachable dead code. Safe by accident is not safe: the boundary now lives in code with tests on it, matching Swift's use of `percentEncodedPath`, which likewise preserves the segments. The dependency was dropped.

> **Symlink escapes are deliberately NOT blocked**, matching Swift's `standardizedFileURL`, which is also purely lexical. Canonicalising here would be stricter than the Mac and would make the same document render differently on the two platforms — the exact outcome the shared web layer exists to prevent. Escaping this way already requires write access to the document's directory. Worth a hardening pass, but on **both** platforms together.

### Task 6: Text patcher — **DONE**

**Files:** `linux/src/patch.rs`, `linux/tests/patch.rs`

**Outcome:** port of `TextPatcher.swift`. All 13 Swift cases ported plus 4 new ones. 17 tests green.

- [x] **Step 1: Offset unit established from source, not assumption.** `editor.js` posts `view.state.doc.length` and CodeMirror change ranges in **UTF-16 code units**; the Swift side applies them to an `NSMutableString`. Rust `String` is UTF-8 and byte-indexed, so `patch.rs` converts to `Vec<u16>`, works there, and converts back. Indexing a Rust string with these offsets directly would corrupt every document containing a non-ASCII character — `multibyte_offsets_are_not_byte_offsets` is the regression guard.
- [x] **Step 2: Implemented and tests ported case-for-case.** Validation runs against the original text before anything is built, so out-of-bounds, inverted, unordered, and overlapping inputs all return `None` for a full-text resync.
- [x] **Step 3: Rust-specific strictness documented** — a patch boundary that splits a surrogate pair cannot be represented as a `String`, so it joins the incoherent-input rejections. Swift's `NSMutableString` tolerates it; the divergence is deliberate and tested.

### Task 7: File watcher — **DONE**

**Files:** `linux/src/watcher.rs`, `linux/tests/watcher.rs`

**Outcome:** same guarantees as `FileWatcher.swift` by a better-fitting mechanism. 10 tests green, no flakes across repeated runs.

- [x] **Step 1: Watch the parent directory, filter by name.** The Swift version watches the file's *inode* and re-attaches when it sees `.delete`/`.rename`, polling on a backoff while the path is missing. inotify fits better: an editor's rename-over arrives as `MOVED_TO` for our filename and a late creation as `CREATE`, so there is no inode to lose and no polling in the common case. Backoff polling remains only for a missing *directory*.
- [x] **Step 2: Trailing-edge debounce** (default 150 ms), matching the Swift work-item cancellation.
- [x] **Step 3: Tests** for in-place write, atomic rename-over, *repeated* rename-over (proves the watch did not die with the first replaced inode), delete-and-recreate, late creation, late directory creation, sibling-file noise being ignored, `stop()` silencing, and idempotent stop/drop.

> The callback fires on the watcher's own thread; Task 8 marshals it to the GTK main loop. This module stays GTK-free so it can be tested headless.

## Phase C — GUI

### Task 8: Application, window, and the preview bridge — **PARTLY DONE** (open: Step 8 embedding)

**Files:** `linux/src/{app,window,preview,resources,js,sandbox,main}.rs`

**Outcome:** documents render. The full "paper & ink" theme, KaTeX, Mermaid, highlight.js, tables and task lists all come up through the shared web layer with **zero changes to `boot.js`** — WebKitGTK exposes the same `window.webkit.messageHandlers` object WKWebView does, so seam 2 needed no port at all.

- [x] **Step 1: Application skeleton** with `HANDLES_OPEN` for D-Bus single-instance.
- [x] **Step 2: Window with a webview** loading `template.html` through the asset scheme. No titlebar widget is set, so the WM draws server-side decorations.
- [x] **Step 3: Script message handler** named `tvmv`; `outline`, `renderComplete`, `sourceClick`, `error` all decoded (via `JSCValue::to_json`).
- [x] **Step 4: Render path** — read file, `render_html(.., source_pos: true)`, `window.tvmv.render`, `applyStyle` from `Settings`. Verified end to end: a `settings.toml` with `theme`, `base_size`, `measure` and `body_font` visibly drives the render.
- [x] **Step 4b: `--snapshot <out.png> <file.md>`** renders offscreen and writes a PNG, waiting on the page's own `renderComplete` — which fires only after the lazy highlight/KaTeX/Mermaid passes settle, so the image is the finished render rather than a race with it. This is how the GUI gets verified without a desktop session in the loop, and it is the groundwork Task 16's `--peek` and Task 14's thumbnailer build on.
- [x] **Step 5: DMABuf renderer forced** — `startup::force_dmabuf_renderer`. Debian/Ubuntu's `disable-dmabuf-nvidia.patch` drops every frame through a CPU copy on NVIDIA: measured at 1200x1200, 19.7 fps and 109% of a core against 61.2 fps and 0.0% with the patch's own override set. Opt-out via `TVMV_NO_FORCE_DMABUF=1`, and an explicit `WEBKIT_*_DMABUF_RENDERER` already in the environment is never overridden.
- [x] **Step 6: Live reload**, scroll position included. Watcher wired in Task 10 Step 6; the position is carried across by `Preview::capture_scroll_ratio` before the render and `restore_scroll_ratio` on `renderComplete`, the same bracket as `ViewerModel.reload`.

  Two things the implementation got wrong first, both caught by `examples/reload_scroll_probe` (which drives the real stack: inotify, both debounces, the promise chain behind `renderComplete`):

  - **The original diagnosis was wrong.** Replacing `#content` does *not* drop WebKitGTK to the top — the scroll offset survives in pixels. So the bug was never a jump to the start; it was that a document whose length changed kept the old *absolute* offset where the Mac keeps the *relative* one. A reload that shortens the document pinned the reader to the bottom (ratio 1.0 against an expected 0.5). The first version of the probe used an equal-length document and passed with the restore commented out, proving nothing; the lengths have to differ for it to discriminate.
  - **`requestAnimationFrame` is not a usable settle on Linux.** `PreviewBridge.waitForLayoutSettle` waits two frames, and the direct port never ran: WebKit withholds frames from a window it considers unviewable, and `raf` was still `0` a second after `renderComplete`. That is the *normal* case for live reload — the user is editing in another application, so our window is unfocused. Reading `scrollHeight` to force a synchronous layout replaces it, which is all a scroll needs once the DOM is final.

- [x] **Step 7: Portal appearance** — closed by Task 11 Step 4. `appearance.rs` reads `org.freedesktop.appearance` `color-scheme` from the XDG portal, falling back to GTK's setting when no portal is running. The original TODO was right that `gtk-application-prefer-dark-theme` is not a reliable signal — `GTK_THEME=Adwaita:dark` does not set it, so `theme: auto` stayed light under a dark GTK theme.
- [ ] **Step 8: Embed the web layer in the binary.** `resources.rs` currently resolves `web/` at runtime (env override, installed path, dev fallbacks — mirroring `ResourceLocator.swift`). Embedding is still wanted so the binary is self-contained.

#### Crate versions are pinned to the system libraries

`webkit6` 0.6.1 needs `gtk4` 0.11 **with the `v4_14` feature** — `gtk::Accessible` is feature-gated behind `v4_10`, and webkit6 uses it unconditionally, so the default feature set fails to compile with a misleading "cannot find type `Accessible`". The features must track the installed libraries: `gtk4/v4_14` for GTK 4.14.5, `webkit6/v2_52` for WebKitGTK 2.52.3.

#### The sandbox opt-out

WebKitGTK confines web processes with bubblewrap, which needs unprivileged user namespaces. Where those are denied the failure is fatal and opaque (`bwrap: setting up uid map: Permission denied`). In the 6.0 API the sandbox is mandatory — `set_sandbox_enabled` was 4.x-only and is gone — so `TVMV_DISABLE_SANDBOX=1` is translated into WebKit's own env opt-out before WebKit initialises, and it prints a warning.

**Deliberately no auto-detection.** A heuristic that guessed wrong would silently drop a security boundary for ordinary users, which is far worse than a clear error inside a container.

### Task 9: Chrome — outline, find, tint — **DONE**

**Files:** `linux/src/{chrome,outline,find}.rs`, rewritten `linux/src/window.rs`

**Outcome:** outline sidebar, find bar with live match count, and document-tinted chrome. 80 tests passing, clippy clean, and scrolling still measures 60.3 fps / 16.7 ms — no regression from the added widgets.

- [x] **Step 1: Outline sidebar** (`GtkPaned` + `GtkListBox` in a `GtkScrolledWindow`), fed by the `outline` message; clicking a row calls `window.tvmv.scrollToAnchor`. Rows indent by heading level, clamped to 1–6 so a document that jumps straight to `h6` cannot indent off-screen. F9 toggles; initial visibility follows `show_outline`.
- [x] **Step 2: Find bar** (`GtkSearchBar`) — Ctrl+F opens and selects the existing query, Enter/Shift+Enter step, Escape closes and clears, live "N of M" counter with an error style on no matches. Both `find` and `findNext` return `{count, index}` from the shared `boot.js`, so the counter is the page's own tally.
- [x] **Step 3: Icons by freedesktop name only** — `sidebar-show-symbolic`, `edit-find-symbolic`, `go-up-symbolic`, `go-down-symbolic`, `window-close-symbolic`. Nothing shipped, so they follow Adwaita/Breeze/Papirus automatically.
- [x] **Step 4: Chrome tint from the rendered page.** `getComputedStyle(document.body).backgroundColor` is read on every `renderComplete` and blended 16% toward white — identical to the Mac's `chromeColor`, so both platforms tint the same for the same document. **This closes the custom-CSS gap**: `theme::paper` handles the pre-render moment from the built-in stylesheet, and this replaces it with the real page colour, so a user stylesheet now tints the whole window.
- [x] **Step 5: No titlebar widget**, so the WM draws SSD.

> **Per-window scoping.** GTK4 style providers attach to the *display*, not to a widget (`WidgetExt::style_context` is deprecated since 4.10), so two windows showing differently-themed documents would overwrite each other's tint. Each window gets a unique `tvmv-win-N` class and its provider's selectors are scoped to it.

> A slim toolbar with the outline and find buttons was added beyond the original step list: with SSD there is no header bar to hang them off, and keyboard-only access is not discoverable.

### Task 10: Editor pane — **DONE**

**Files:** `linux/src/{document,editor}.rs`, `linux/src/window.rs`, `linux/src/preview.rs`

**Outcome:** editing, live preview, save, live reload, and both conflict prompts. 93 tests passing, clippy clean, still 16.7 ms/frame. Verified end to end on a real file: one line added through the editor, saved, and the on-disk diff was exactly that line — LF preserved, valid UTF-8, no temp file left behind.

- [x] **Step 1: Editor webview** in the paned split; Ctrl+E toggles. `editor.html` loads on **first** open — CodeMirror is 1.5 MB and a reader who never edits should never pay for it. Reopening re-seeds text with `resetHistory: false` so undo survives.
- [x] **Step 2: Patch path** — `textPatch` applies through Task 6's `TextPatcher`; a re-render is scheduled debounced by document size (250 ms / 600 ms / 1 s over 1 MB and 4 MB), matching `ViewerModel.renderDebounceDelay`. A generation counter drops superseded renders, so fast typing cannot queue a parse per batch. An incoherent payload pulls the whole document via `getText` rather than guessing.
- [x] **Step 3: Two-way sync** — editor `scrolled` drives `scrollToSourceLine`; `cursorMoved` drives `revealSourceLine` (which only moves if the block is offscreen).
- [x] **Step 4: Save** (Ctrl+S) with a `•` dirty marker in the title. Writes atomically through a temp file beside the target, and **carries the original permissions over** — writing through a temp file otherwise silently resets the mode.
- [x] **Step 5: Close guard** — Cancel/Discard/Save on unsaved changes. A failed save keeps the window open; closing anyway would lose the edits.
- [x] **Step 6: External-change conflict** — Task 7's watcher wired through an `async-channel` to the GTK main loop (it runs off-thread and must not touch widgets). Clean document reloads silently; a dirty one prompts *Keep my edits* / *Reload from disk*, defaulting to keeping them.

> **Newline fidelity.** `text` is LF-normalised because CodeMirror and `data-sourcepos` both count LF lines, and the file's original style is restored on save — otherwise opening and saving a CRLF file rewrites every line into a whole-file diff. A single stray CRLF does not flip an LF document.

> **Recognising our own saves.** The watcher fires on our save exactly as on anyone else's and cannot tell them apart. Comparing content against the last-saved text can; a timing window cannot, and getting it wrong means an endless save/reload loop. The comparison runs on LF-normalised text so saving a CRLF file does not look foreign.

#### Fixed here: a multi-window asset-routing bug

Each window registered the `tvmv-asset://` handler on the **shared default** `WebContext`, and a context takes one handler per scheme — so the newest window's handler served every window and `tvmv-asset://doc/` resolved relative images against the wrong document. It stayed invisible because the test documents have no relative images. One handler now looks the requesting view up via `URISchemeRequest::web_view()`.

### Task 11: Settings window and portal dialogs — **DONE**

**Files:** `linux/src/settings_ui.rs`, `linux/src/appearance.rs`, `linux/src/{window,app}.rs`

**Outcome:** every setting, applied live to all open windows and persisted immediately. 100 tests passing, clippy clean.

- [x] **Step 1: Settings window** — plain `GtkWindow` + `GtkListBox` rows, no libadwaita, so it inherits the user's GTK theme. Theme, body/code font, text size, line width, full width, show outline, custom CSS. Escape closes; there is no OK/Cancel because everything applies live, matching the Mac app.
- [x] **Step 2: Custom CSS via the XDG portal** (`GtkFileDialog`), so KDE users get the Plasma chooser. Injected through the shared `applyUserCSS`.
- [x] **Step 3: Live application** — a shared process-wide `Settings` is pushed to every open window via `app::apply_settings_to_all`, so two windows can never disagree about the theme.
- [x] **Step 4: `theme: auto` now reads the portal** (`org.freedesktop.appearance` `color-scheme`), closing the Task 8 TODO. GTK's `gtk-application-prefer-dark-theme` was **not a reliable signal** — `GTK_THEME=Adwaita:dark` does not set it, so auto stayed light under a dark theme. Falls back to the GTK setting when no portal is running. Values map 1=dark, 2=light, and **anything else defers** rather than being guessed at.

> **Font values are one family, never a chain.** The pickers list installed families from fontconfig via Pango, so a user cannot enter one that does not resolve. A configured-but-missing family (`Source Serif 4` ships with the Mac app, not with Linux) is shown as "(not installed)" rather than being silently replaced by whatever sorts first — which would rewrite the setting just by opening the window.

#### Two bugs found by checking rather than assuming

- **Custom CSS never applied at startup.** It was wired only to the settings dialog's change handler, so a configured stylesheet was ignored until the user opened Settings. Now injected on every page load. Verified: the page background is `#00857c` with the example theme against `#fbf8f2` built-in.
- **The font dropdown mapped indexes wrongly.** Prepending the "(not installed)" placeholder shifted the model by one against the family list, so choosing a font would have stored a different one. Values are now a parallel list.

### Task 12: Print and Save-as-PDF — **DONE**

**Files:** `linux/src/print.rs`, `linux/src/window.rs`, `linux/src/main.rs`

**Outcome:** 103 tests passing, clippy clean. Verified by exporting `Fixtures/showcase.md` and rendering the result: a valid 2-page PDF, fonts embedded, with the shared print rules visibly applied — white page, full-width measure, link URLs expanded.

- [x] **Step 1: `WebKitPrintOperation`** driven by `run_dialog` (Ctrl+P). That is GTK's dialog, which on a portal-enabled desktop is the portal's, so KDE users get the Plasma one. It already offers "Print to File".
- [x] **Step 2: Save-as-PDF** (Ctrl+Shift+P) — a destination chooser, then `PrintSettings` with the `Print to File` printer plus `output-uri` and `output-file-format=pdf`, printed with no dialog. The suggested name is derived from the document (`README.md` -> `README.pdf`, keeping interior dots).
- [x] **Step 3: Print CSS verified** rather than assumed. It comes from the shared `app.css`, so this is the Mac app's output, not a second implementation.
- [x] **Step 3b: `tvmv --pdf <out.pdf> <file.md>`** renders headless. It waits for the page's own `renderComplete`, so the lazy KaTeX and Mermaid passes are in the output — printing earlier drops them. This is what makes the print path testable without a desktop session.

## Phase D — Desktop integration and packaging

### Task 13: Desktop entry, icons, MIME — **DONE**

**Files:** `linux/data/dk.dyregod.tvmv.desktop`, `linux/data/icons/hicolor/*/apps/`, `linux/data/apparmor/tvmv`

- [x] **Step 1: Hicolor icon set** — 16/24/32/48/64/128/256/512 generated from `build/icon-1024.png`.
- [x] **Step 2: `.desktop` entry** with `MimeType=text/markdown;text/x-markdown;`, `Exec=tvmv %F`, and **`StartupWMClass=tvmv`** — verified against the running app's actual `WM_CLASS`, without which the shell shows a second iconless dock entry instead of grouping windows. `desktop-file-validate` passes with no hints.
- [x] **Step 5: AppArmor profile** — see Task 18; required for the WebKit sandbox on Ubuntu 24.04.
- [ ] **Step 3: AppStream metainfo** for GNOME Software / Discover.
- [x] **Step 4: Verified** — `xdg-mime query default text/markdown` returns `dk.dyregod.tvmv.desktop`. Confirmed against a per-user install (`PREFIX=$HOME/.local`), not a root one; the root path is the same code in `build/linux.fish`.

### Task 14: Thumbnail card + freedesktop thumbnailer — **DONE**

**Files:** `linux/src/card.rs`, `--thumbnail` in `main.rs`, `linux/data/tvmv.thumbnailer`

- [x] **Step 1: `card.rs`** — paper card with the first heading, a rule, and opening prose, in Pango/Cairo. Skips YAML front matter and fenced code (a card showing `layout: post` says nothing about the document), strips inline markup, and drops link/image *targets* while keeping link text.
- [x] **Step 2: `tvmv --thumbnail <in> <out> <size>`**, argument order matching the spec's `%i %o %s`.
- [x] **Step 3: Pathological input** — empty files, unclosed fences, 10k-character headings, NUL bytes, non-UTF-8 (read lossily). None panic; a file manager runs this over whatever is on disk.
- [x] **Step 4: `.thumbnailer` registration**, installed by `build/linux.fish`. One file covers Nautilus, Nemo, Caja, PCManFM and Thunar (via tumbler).
- [x] **Step 5: Benchmark** — **42 ms** for the README, reading a bounded 64 KB prefix so a multi-megabyte file costs the same as a small one. No GTK application and no WebKit.

> Drawing scales off the card size rather than using fixed pixels, so 32px and 512px are the same design rather than one being a shrunken copy.

> `--thumbnail` and `--html` now skip the WebKit environment setup entirely — otherwise a file manager thumbnailing a directory got a sandbox warning per file.

### Task 15: KDE thumbnail plugin — **PARTIAL**

**Files:** `linux/src/capi.rs`, `linux/include/tvmv_card.h`, `linux/kio-thumbnail/README.md`

- [x] **Step 1: C ABI exported** from the Rust cdylib (`tvmv_card_render_png` / `tvmv_card_free`), so the plugin draws the *same* card as the freedesktop thumbnailer instead of reimplementing it. **Verified from real C**: PNG magic checked, null input refused, NULL title tolerated, double-free avoided.
- [ ] **Step 2–4: the C++ plugin itself.** Not written as compilable code, because this machine has neither `cmake` nor KDE development packages and installing them needs root — shipping C++ that has never been compiled into a repo meant for sharing would be worse than shipping none. `linux/kio-thumbnail/README.md` records the build recipe and the KF5-vs-KF6 detection Ubuntu 24.04 forces (it has no `libkf6kio-dev`).

> The ABI contract had a wart the C test found: `out_len` kept its stale value when the call refused null input. It is now cleared before any early return.

### Task 16: `tvmv --peek` — **DONE**

**Files:** `linux/src/window.rs` (`DocumentWindow::peek`), `linux/src/app.rs`

- [x] **Step 1–3: Chromeless preview** — no toolbar, no find bar, no sidebar; Escape closes.
- [x] **Step 4: Warm-open latency measured at 0.07 s.** It routes through `GApplication::open` with a hint, which forwards to the already-running instance and its warm WebProcess. A hint has no command-line spelling, so `--peek` registers and calls `open` directly.
- [ ] **Step 5: Promotion** of a peek window to a full one.

> `run` must be called even when the instance is remote: it is what unregisters from D-Bus, and returning without it logs "did not unregister from D-Bus before destruction".

### Task 17: File-manager context menus — **DONE**

**Files:** `linux/data/extensions/tvmv-preview.py`

- [x] **Step 1: Sushi verified**, as the plan required rather than assumed. `/usr/share/sushi` contains only `.gresource` bundles — the viewers are compiled in, with no plugin directory. So there is no Sushi extension point, and the context menu is the supported path.
- [x] **Step 2: MenuProvider extension** adding **Preview with TVMV**, invoking `tvmv --peek`. Matches on MIME type and falls back to the suffix, since some managers report `text/plain` for `.md`.
- [x] **Step 3: Installed** to `~/.local/share/{nautilus,nemo,caja}-python/extensions/`, skipping managers that are not present. One file serves all three; they expose the same interface under different module names.
- [x] **Step 4: Degrades cleanly** — `python3-nautilus` is a soft dependency. It is not installed here, so **the extension is written and syntax-checked but has not been run.**

### Task 18: Local install script — **DONE** (now the primary path)

**Files:** `build/linux.fish`

Verified end to end into a scratch prefix: 86 files installed, the installed binary finds its web assets with no environment variable and runs at **60.0 fps / 1.0 vsync per frame**, and `uninstall` removes everything it placed.

- [x] **Step 1: `cargo build --release`**, then install binary, web assets, `.desktop`, icons, and the AppArmor profile.
- [x] **Step 2: `uninstall`** removes what it installed and refreshes the desktop and icon caches. `share/applications/mimeinfo.cache` is deliberately left — it is a shared cache owned by the desktop database, not by us.
- [x] **Step 3: Refuses to run on non-Linux**, pointing at `build/bundle.fish`, so it can never be confused with the macOS bundler.
- [x] **Step 4: Root only where needed** — it probes the nearest existing ancestor of `PREFIX`, so a prefix under `$HOME` needs no `sudo`. The AppArmor profile always needs root, and failing to load it is a warning rather than a failure: the app detects the situation and falls back.

> Two fish traps worth remembering: an empty variable used as a command prefix gives "The expanded command was empty", and `command` swallows flags like `-Dm755` as its own options. A one-line function (`function asroot; $argv; end`) is the form that works.

### Task 19: Flatpak — **secondary**

> **Demoted.** A native install is now the primary artefact: it measured faster (60 fps at ~0% CPU vs 41 fps and 3-4.5 cores), the dmabuf fix works without it, and Flatpak apps pick up the runtime's theming rather than the desktop's — the mis-scaled cursor being the visible symptom. Kept for people who prefer it and for distros with an old WebKitGTK.

> **Original rationale.** Beyond pinning the WebKitGTK version, the Flatpak is
> the *only* build that gets working dmabuf zero-copy on NVIDIA: Debian/Ubuntu's
> `disable-dmabuf-nvidia.patch` forces WebKit onto SHM buffers, costing a full
> CPU core and roughly half the frame rate at large window sizes. The GNOME
> runtime builds WebKit unpatched. Measured on this machine: 0 dmabuf imports
> under the `.deb`, 101 under the runtime. See the spec's root-cause section.

**Files:** Create `linux/data/dk.dyregod.tvmv.yml`

- [ ] **Step 1: Manifest** on the GNOME runtime (pins WebKitGTK), bundling Source Serif 4 and the mono fallback font.
- [ ] **Step 2: Offline build** — vendor the cargo registry; the app must render with no network at runtime.
- [ ] **Step 3: Portal permissions** — filesystem access for opening documents, no network.
- [ ] **Step 4: Verify** `flatpak run dk.dyregod.tvmv Fixtures/showcase.md` renders identically to the local build.

### Task 20: Documentation

**Files:** Modify `README.md`, `THIRD-PARTY-LICENSES.md`

- [ ] **Step 1: Linux section** — build deps, `build/linux.fish`, Flatpak install, the DMABuf workaround.
- [ ] **Step 2: Document every preview surface** — thumbnails, Dolphin's Information Panel, `--peek`, the context menu, plus copy-pasteable `yazi` / `ranger` / `lf` preview-command snippets.
- [ ] **Step 3: Record the honest limit** — Space in Nautilus stays Sushi's until the upstream markdown viewer lands; state the workaround (context menu / a WM keybinding on `tvmv --peek`).
- [ ] **Step 4: Licenses** — add Source Serif 4 (OFL) and the bundled mono font.
- [ ] **Step 5: Final cross-platform gate** — Swift suite green on the Mac, `cargo test` green on Linux, golden tests green in both.
