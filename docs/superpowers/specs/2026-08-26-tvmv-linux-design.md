# TVMV for Linux — design

Date: 2026-08-26
Status: approved in discussion; this document is the written record.

## Goal

Ship TVMV as a native Linux desktop app with the same rendering pipeline,
"paper & ink" theme, editor, and feel as the Mac app — fast to open, correctly
wired into whatever desktop the user runs, and looking like *TVMV* rather than
like a port. The Mac and iOS apps and their build pipelines are unaffected.

Decisions already made:

- **No Swift port.** The Linux shell is a fresh **Rust** program. The Swift
  under `Sources/` is not reused, translated, or cross-compiled.
- **The web layer is shared verbatim.** `app.css`, `boot.js`, `editor.js`,
  `editor.html`, `template.html`, and the vendored bundle are promoted to
  `/web` at the repo root and consumed by all three shells. Not forked.
- **GTK4 without libadwaita** + **WebKitGTK 6.0**. libadwaita overrides the
  user's GTK theme by design, which is the mechanism that makes an app look
  imported on KDE and tiling WMs.
- **The same cmark-gfm C library**, not a Rust reimplementation, so both
  platforms emit byte-identical HTML.
- **Flatpak** is the primary distribution artifact.
- Editing is included from the start — parity with the Mac app, not a viewer
  subset.

## Why the web layer is the port

`Sources/TVMVCore/Resources/web/` is where TVMV actually lives: the theme, the
typography, outline extraction, find-in-page with match counts, source-position
sync, scroll-ratio restore, lazy loading of KaTeX / Mermaid / highlight.js, and
the CodeMirror editor. That is ~40 KB of hand-written CSS+JS plus 6.3 MB
vendored.

The Swift is 2,684 lines and most of it is shell: window and menu code, a
WebView wrapper, settings persistence, file watching. Rewriting the web layer
for Linux would produce two themes that drift within a month. Rewriting the
shell costs a few hundred lines and buys a native app.

## The three seams

The shell implements exactly three interfaces against the shared web layer.
Each has a direct WebKitGTK equivalent:

| Seam | macOS | Linux |
|---|---|---|
| Asset serving | `WKURLSchemeHandler` for `tvmv-asset://app/*` and `tvmv-asset://doc/*` | `webkit_web_context_register_uri_scheme` — same host routing, same path-traversal confinement |
| JS → native | `window.webkit.messageHandlers.tvmv.postMessage` | **identical JS API**; native side registers via `user_content_manager.register_script_message_handler("tvmv")` |
| native → JS | `callAsyncJavaScript` / `evaluateJavaScript` | `webkit_web_view_evaluate_javascript` |

The JS→native seam needs **zero changes to `boot.js` or `editor.js`** —
WebKitGTK exposes the same `window.webkit.messageHandlers` object WKWebView
does. The message vocabulary is unchanged on both sides:

- Preview → native: `outline`, `renderComplete`, `sourceClick`, `error`
- Editor → native: `ready`, `textPatch`, `cursorMoved`, `scrolled`, `error`
- Native → preview: `window.tvmv.{render, applyStyle, setTheme, scrollToAnchor,
  getScrollRatio, setScrollRatio, topVisibleSourceLine, scrollToSourceLine,
  revealSourceLine, find, findNext, clearFind, applyUserCSS}`

## Repository layout

`linux/` mirrors the existing `ios/` convention: a shell directory alongside
the shared core, with its own build definition.

```
web/                      PROMOTED: canonical shared web layer
                          app.css, boot.js, editor.{html,css,js},
                          template.html, vendor.json, vendor.fish, vendor/
Sources/TVMVCore/Resources/web/   generated copy (gitignored) — SwiftPM input
Sources/, ios/            unchanged Swift/iOS shells
linux/Cargo.toml          Rust shell crate
linux/src/                app, window, webview, bridges, settings, watcher
linux/data/               .desktop, AppStream metainfo, .thumbnailer,
                          hicolor icons, Flatpak manifest
linux/target/             cargo output (gitignored)
build/sync-web.fish       web/ -> Sources/TVMVCore/Resources/web/
build/linux.fish          cargo build + install/uninstall + flatpak
Fixtures/                 shared golden fixtures for both test suites
```

## Markdown engine

The Linux shell compiles **the same cmark-gfm C source the Mac links**, vendored
as a git submodule at `linux/vendor/swift-cmark`, pinned to the revision
`Package.resolved` names (`0101bf2c`). `linux/src/render.rs` mirrors
`MarkdownRenderer.swift` exactly: register the GFM core extensions once, attach
`table`, `strikethrough`, `autolink`, `tasklist` in that order, and pass
`CMARK_OPT_SOURCEPOS` when the editor is open.

This closes the version-skew risk **by construction** rather than detecting it
after the fact. `data-sourcepos` is the anchor the editor↔preview sync maps
through; a parser that is *almost* cmark-gfm produces sync that is almost right,
which is worse than obviously broken. Two shells compiling identical C with
identical options cannot diverge.

Two mechanisms reach one revision — SwiftPM on the Mac, a submodule on Linux —
so `linux/tests/vendor_pin.rs` asserts they agree and fails loudly if either
side is bumped alone.

Upstream builds these sources with CMake, but swift-cmark checks in the headers
CMake would generate (`cmark-gfm_config.h`, `cmark-gfm_version.h`, `export.h`)
so that SwiftPM can compile them directly. The Rust `cc` crate can therefore
compile them too. Consequences worth stating:

- **No `libcmark-gfm-dev` dependency.** Distro cmark-gfm versions are irrelevant.
- **No CMake at build time.**
- The rejected alternative was comrak (pure Rust, no C, but a reimplementation
  that would need continuous golden-test babysitting) and the second rejected
  alternative was Debian's `libcmark-gfm` 0.29.0.gfm.6, which is not
  necessarily the same upstream point as the Mac's pin.

## Fast

Startup and window-open latency are the features here, so they are designed
rather than hoped for.

- **Single instance via D-Bus.** `gtk::Application` with `HANDLES_OPEN` gives
  DBus activation for free: `tvmv a.md b.md` against a running instance is one
  IPC message, and windows appear without a process launch. This reproduces the
  Mac "reuses a running instance" behavior with no code of our own.
- **Shared web process.** New windows use
  `webkit_web_view_new_with_related_view` so they share the existing
  WebProcess. No process spawn per document.
- **Assets embedded in the binary.** The `web/` tree is compiled in and served
  from memory by the URI scheme handler. No disk I/O, no unpacking, nothing to
  install alongside the binary.
- **Lazy vendor loading already exists.** `template.html` deliberately does not
  reference KaTeX, Mermaid, or highlight.js; `boot.js` injects them on demand.
  Mermaid's 3.2 MB costs nothing until a document contains a diagram. Preserve
  this — do not "simplify" it into static script tags.
- **Incremental editing.** Keep the `TextPatcher` path: the editor sends
  patches, not whole documents, on every keystroke.

Known trap: WebKitGTK's DMABuf renderer produces blank web views on some
drivers. Detect and fall back to `WEBKIT_DISABLE_DMABUF_RENDERER=1` rather than
shipping a mystery blank window.

### Scrolling: what was measured, and the ceiling that remains

Two separate problems were found here. Measure with `--frame-bench` (frame clock
`after-paint`), never `requestAnimationFrame` cadence — rAF is driven by vsync
and reports a clean 60 fps while frames are being dropped, which sent an entire
investigation down the wrong path. Check `/proc/loadavg` before trusting any
number; a background `cargo build` silently halved two rounds of results.

#### 1. GNOME on X11 with NVIDIA — fixed by switching to Wayland

`examples/gtk_frame_probe.rs` is a WebKit-free GTK4 window drawing one rectangle.
Under the X11 session it measured **identically to the full app**, which is what
exonerated TVMV: GTK could not paint faster than two vsyncs even idle in a
300x300 window, and large windows fell to three. Matches long-standing NVIDIA +
mutter reports of framerate locking to half the refresh rate.

Switching the session to Wayland fixed it: the probe went 30.1 -> **58.9 fps
(1.0 vsync)**, TVMV idle 32.1 -> **51.8 fps**, TVMV scrolling a small window
30.4 -> **59.8 fps (1.0 vsync)**.

#### 2. WebKitGTK main-frame scrolling at HiDPI — unresolved

A full-size window (900x1000 logical = **1800x2000 device pixels** at scale 2)
still scrolls at **30 fps / 2.0 vsyncs**. That is WebKitGTK repainting 3.6
megapixels on the main thread each frame. Everything tried, on an idle machine:

| lever | result |
|---|---|
| `ThreadedScrolling` feature | **core-dumps the web process** on 2.52 — off by default for a reason; kept opt-in via `TVMV_THREADED_SCROLLING=1` for retesting |
| `HardwareAccelerationPolicy::Always` | does not stick; getter reports `Never` even on a fresh unattached `Settings` |
| `GSK_RENDERER` ngl / gl / cairo | 30.7 / 24.3 / 33.7 fps — `gl` clearly worse, `cairo` marginally best |
| `WEBKIT_DISABLE_DMABUF_RENDERER` | no change |
| `WEBKIT_DISABLE_COMPOSITING_MODE` | no change |
| `will-change: transform` on the content | no change |

#### Root cause: Debian/Ubuntu's `disable-dmabuf-nvidia.patch`

**Exactly one thing is broken, and it is a distribution patch.** Debian and
Ubuntu carry `disable-dmabuf-nvidia.patch` in the `webkit2gtk` source package,
which disables WebKitGTK's DMABuf renderer whenever an NVIDIA proprietary driver
is present. WebKit then hands frames to the UI process as **shared-memory**
buffers, so GTK uploads every pixel on the main thread, every frame.

Not the driver, not GTK, not Wayland, not the display, not the engine's
architecture, and nothing in TVMV.

##### Proof

The decisive A/B is the *same machine, same NVIDIA driver, same display*, with
patched (Ubuntu) versus unpatched (Flatpak GNOME 50 runtime) WebKitGTK:

| | Ubuntu `libwebkitgtk-6.0-4` | Flatpak `org.gnome.Platform//50` |
|---|---|---|
| `GDK_DEBUG=dmabuf` imports | **0** | **101** (`Imported 2048x1444 XR24:0x300000000e08014 dmabuf as GL_TEXTURE_2D`) |
| `webkit://gpu` -> Policy | `never`, and cannot be set | — |

Host GTK 4.14 *does* contain the `Importing dmabuf` / `Creating dmabuf texture`
log strings, so the zero is a real absence rather than a logging difference. The
modifier in the working case (`0x300000000e08014`) is NVIDIA block-linear, i.e.
genuine GPU-native zero-copy, not a linear fallback.

Supporting measurements:

- A **GPU-path** GTK4 control (`gtk_frame_probe`, GSK colour node) holds
  **59.6 fps at every size** including 1200x1200 -- so GTK, the driver, Wayland
  and the 5K display are all healthy.
- UI-process CPU scales linearly with window area: 9% at 0.24 Mpx, 46% at
  0.80 Mpx, 100% at 1.96 Mpx, 109% at 5.76 Mpx, all on the GTK main thread.
- `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` measures **identically to baseline** --
  because baseline is already on the SHM path. `DISABLE_GBM=1` likewise.
- `webkit://gpu` reports `Policy: never` and `VBlank type: Timer`; the C enum
  (`ALWAYS=0, NEVER=1`) matches the Rust binding, so the refused setter is
  WebKit overriding the request, not a binding bug.

##### Status upstream

Upstream WebKit **declined** this change: bug 262607, "[GTK] Disable DMABuf
renderer for NVIDIA proprietary drivers", RESOLVED **WONTFIX**. The patch exists
only in Debian/Ubuntu. It was dropped once ("all Nvidia-related bugs are supposed
to be fixed upstream") and reinstated after Debian #1082139, and is guarding
against 2023-era failures (blank windows, flickering) on far older drivers. On
610.43.02 the zero-copy path demonstrably works.

##### The fix: `WEBKIT_FORCE_DMABUF_RENDERER=1`

**The same distribution patch ships its own override**, so nothing needs
rebuilding, repackaging, or sandboxing. `startup::force_dmabuf_renderer()` sets
it before WebKit initialises. Measured on the system `.deb` WebKit:

| window (logical, scale 2) | default | forced |
|---|---|---|
| 900x1000 | 30.3 fps, median 33.3 ms | **60.6 fps, median 16.7 ms** |
| 1200x1200 | 19.7 fps, median 52.3 ms | **61.2 fps, median 16.7 ms** |
| 1600x1400 | 9.2 fps, median 113.1 ms | **60.7 fps, median 16.7 ms** |
| UI-process CPU @1200x1200 | 109% of a core | **0.0%** |
| dmabuf imports | 0 | 282 |

One vsync at **every** size — the size dependence disappears entirely, because
the UI process stops touching pixels at all.

It is opt-**out** (`TVMV_NO_FORCE_DMABUF=1`) rather than opt-in: the patch exists
because some NVIDIA setups showed blank windows and flicker, and a blank window
is a worse failure than slow scrolling. An explicit
`WEBKIT_FORCE_DMABUF_RENDERER` or `WEBKIT_DISABLE_DMABUF_RENDERER` in the
environment is always respected over ours.

##### Also verified: the Flatpak fixes it too, less well

Built and installed (`linux/data/dk.dyregod.tvmv.yml`, host binary variant) and
measured against the `.deb` on the same machine:

| window (logical) | .deb — patched, SHM | Flatpak — unpatched, dmabuf |
|---|---|---|
| dmabuf imports | **0** | **376** |
| 700x700 | 59.5 fps, median 16.7 ms | 58.5 fps, median 16.7 ms |
| 900x1000 | 29.8 fps, median 33.3 ms | 41.1 fps, **median 17.4 ms** |
| 1200x1200 | 20.5 fps, median 51.1 ms | 30.5 fps, median 33.0 ms |

At the default window size the median frame lands within **one vsync** instead of
two. The mechanism is confirmed fixed.

**But it costs CPU**: ~100% of one core (13 threads) on the `.deb`, versus
329-457% (50 threads) in the Flatpak. `__GL_YIELD=USLEEP` does not change it, so
it is real work rather than NVIDIA driver spinning — most likely the newer
WebKit's Skia CPU rasterisation thread pool. Fine on a desktop; worth measuring
on a laptop before calling it a straight win.

**Confound, stated plainly:** the Flatpak changes three variables at once — the
missing patch, WebKitGTK 2.52.3 -> 2.4.16.9 soname (newer build), and GTK
4.14.5 -> 4.22.4. The dmabuf mechanism is isolated and proven (0 vs 376 imports,
with the host GTK verified to contain the log strings). The *net* performance
profile, including the CPU cost, mixes all three.

##### What this means for TVMV

The shell fixes this itself with one environment variable, so **both** the
`.deb` and the Flatpak are fine. The Flatpak keeps its Task 19 justification —
pinning the WebKitGTK version — but is no longer required to get zero-copy, and
measured *worse* than the fixed `.deb` (41 fps vs 60 fps at 900x1000, and 3-4.5
cores of CPU against ~0).

##### Two conclusions reached here that were wrong

- *"Engine capability gap -- no threaded scrolling."* Wrong: a pure CSS
  `transform` animation was equally slow, so compositing was never the issue.
- *"NVIDIA caps external monitors at 30 fps under Wayland."* Wrong, and it was
  search results trusted over measurement. The GPU-path control disproved it.

The method that worked every time was **A/B against a control that removes the
component under suspicion**. The first control was itself misleading: it drew
with cairo, which is CPU rasterisation by design and slows at large sizes on any
hardware. Only a GSK/GPU-path control isolated the variable.

A caution for `is_feature_enabled`: `WebKitFeature::is_default_value()` reports
whether a feature is *at* its default, **not** whether it is *on*. Conflating
them produced a wrong "async scrolling is already enabled" conclusion here.

### Earlier notes on the X11 ceiling

On the development machine — NVIDIA 610.43.02, GNOME on **X11**, a 5120×2880
desktop at scale 2 — scrolling is visibly sluggish, and it is **not TVMV**.

`examples/gtk_frame_probe.rs` is a WebKit-free GTK4 window drawing one rectangle
with cairo. It measures identically to the full app:

| window (device px) | painted | vsyncs/frame |
|---|---|---|
| 300×300 probe | 30.1 fps | 2.0 |
| 900×900 probe | 20.8 fps | 3.0 |
| TVMV 800×600 | 30.4 fps | 2.0 |
| TVMV 1800×2000 | 20.7 fps | 3.0 |
| TVMV **idle**, nothing moving | 32.1 fps | 2.0 |

GTK cannot paint faster than **two vsyncs** on this session even when idle with a
tiny window, and large windows fall to three. None of these changed it:
`GSK_RENDERER` (`ngl`/`gl`/`cairo`), `WEBKIT_DISABLE_DMABUF_RENDERER`,
`WEBKIT_DISABLE_COMPOSITING_MODE`, `HardwareAccelerationPolicy`,
`__GL_SYNC_TO_VBLANK=0`, `__GL_MaxFramesAllowed=1`. Chromium is smooth because it
does not present through GSK and the GTK frame clock at all.

This matches long-standing NVIDIA + mutter reports of framerate locking to half
the refresh rate. The plausible remedy is a **Wayland session** rather than X11;
it is a system configuration matter, not a TVMV one.

**Consequences for the plan:** measure paint rate with `--frame-bench` (frame
clock `after-paint`), never `requestAnimationFrame` cadence — rAF is driven by
vsync and reports a clean 60 fps while frames are being dropped, which sent an
entire investigation down the wrong path. And benchmark against the GTK-only
probe before attributing any slowness to WebKit or to the web layer.


## Looking native on every shell

The target is **correctly wired into the desktop**, not indistinguishable from
a stock Breeze or Adwaita app. TVMV already tints its chrome to a lightened
page background (`chromeColor`), so on macOS it looks like TVMV, not like a
stock Mac app. That identity carries over; what must not carry over is being
wired up wrong.

Ranked by how foreign it reads:

1. **Dialogs via XDG portals.** File chooser (Custom CSS → Choose…) and print /
   Save-as-PDF go through the desktop portal, so KDE users get Plasma dialogs
   and GNOME users get GTK ones from the same code. Automatic under Flatpak.
2. **Icons by name, never shipped.** The entire native icon surface is seven
   symbols, all with exact freedesktop equivalents:

   | SF Symbol | freedesktop name |
   |---|---|
   | `magnifyingglass` | `edit-find-symbolic` |
   | `chevron.up` / `chevron.down` | `go-up-symbolic` / `go-down-symbolic` |
   | `xmark` | `window-close-symbolic` |
   | `exclamationmark.triangle.fill` | `dialog-warning-symbolic` |
   | `exclamationmark.octagon.fill` | `dialog-error-symbolic` |
   | outline toggle | `sidebar-show-symbolic` |
   | edit toggle | `document-edit-symbolic` |

   Resolved against the installed icon theme, these follow Adwaita, Breeze, or
   Papirus automatically. Shipping our own set is what makes an app look
   imported.
3. **Appearance from the portal.** Read `org.freedesktop.appearance`
   `color-scheme` rather than a GNOME-specific API, so `theme: auto` is correct
   on KDE and XFCE too.
4. **Chrome font from GTK settings** (`gtk-font-name`). Document typography
   stays ours — that is the app's whole point.
5. **Decorations.** No titlebar widget is set, so the window manager draws
   server-side decorations: KDE and tiling-WM users get what they expect. A
   client-side header bar is available as an option for GNOME users who prefer
   it; libadwaita would have made that choice impossible.
6. **Shortcuts.** Ctrl+F / S / P / W / R, Ctrl+, for settings, F9 for the
   outline sidebar.

Widget mapping: `GtkPaned` for the outline split, `GtkSearchBar` for find,
a plain `GtkWindow` with `GtkListBox` rows for Settings, `GtkCssProvider` on
the window for the `chromeColor` tint.

**Fonts.** The Mac defaults are `Source Serif 4` and `Menlo`; neither exists on
Linux. Source Serif 4 is OFL and gets bundled in the Flatpak.

A font setting is **one family name, never a comma-separated chain.** Both
`boot.js` and `editor.js` emit `JSON.stringify(cfg.monoFont) + ", monospace"`,
so the value becomes a single quoted CSS family with a generic fallback already
appended. A chain would be quoted whole, match no installed family, and fall
back to the generic — silently, and identically to having set nothing. The
quoting is there because an unquoted `Source Serif 4` is invalid CSS (an
identifier cannot start with a digit).

So the Linux mono default is `DejaVu Sans Mono` — present on effectively every
desktop install — and the generic fallback boot.js appends covers the rest. The
settings font picker (Task 11) enumerates installed families through fontconfig
so a user cannot type a family that does not resolve.

## Preview integration

Linux has no single QuickLook. It has five separate surfaces, and TVMV should
be present on all of them it can reach. Ranked by reach per unit of work:

### 1. Freedesktop thumbnails — every GTK-family file manager

A `--thumbnail <in.md> <out.png> <size>` mode of the same binary draws a
paper-coloured card with the document's first heading and opening lines using
Pango/Cairo. **No WebKit** — milliseconds per file, no web process, safe to run
across a directory of hundreds of files.

One `.thumbnailer` file registers it with the shared freedesktop spec, which
covers Nautilus, Nemo, Caja, PCManFM, and Thunar (via tumbler). This is the
single broadest integration available.

### 2. KDE / Dolphin — a KIO thumbnail plugin

Dolphin does not read `.thumbnailer` files; it needs a
`KIO::ThumbnailCreator` plugin. That plugin is worth writing, because on KDE it
serves **two** surfaces at once: grid thumbnails *and* the Information Panel's
large preview. The Information Panel is the closest thing KDE has to
QuickLook, so this is genuine preview integration rather than just prettier
icons. It shares the Cairo/Pango drawing code with the thumbnailer.

### 3. `tvmv --peek` — the Sushi-shaped experience we control

A chromeless, ESC-to-close, borderless preview window: no sidebar, no editor,
no find bar, sized to the screen and centred. Against a warm D-Bus instance it
opens in single-digit milliseconds, which is the entire point of a spacebar
previewer.

This is the piece everything else points at — the context-menu item invokes it,
a user's WM keybinding can invoke it, terminal file managers invoke it. Owning
it means the preview experience does not depend on any file manager's plugin
API.

### 4. Context-menu entries — Nautilus, Nemo, Caja

`libnautilus-extension` (and its Nemo/Caja equivalents, all reachable from
Python via `nautilus-python`) exposes a stable `MenuProvider` interface. A
small extension adds **Preview with TVMV** to the right-click menu for
`text/markdown`, invoking `tvmv --peek`. Cheap, and it puts TVMV where people
look when Space does not do what they wanted.

Note this is a *menu* provider, not a preview-pane provider — modern Nautilus
has no third-party preview-pane API. The menu is the supported path.

### 5. Terminal file managers — documentation, not code

`yazi`, `ranger`, and `lf` all take a user-configured preview command. Ship
copy-pasteable config snippets in the README rather than any code.

### GNOME Sushi and nemo-preview

Sushi is the one surface with no supported extension point: its viewers
(`text`, `html`, `pdf`, `image`, `audio`, `video`, `office`) are GJS modules
compiled into the app's gresource bundle, selected by MIME type, with no plugin
directory to drop a viewer into. `nemo-preview` is a fork of Sushi and inherits
the same limitation. `text/markdown` therefore falls through to Sushi's plain
text viewer and shows raw source.

**This must be re-verified against the currently installed Sushi before the
work is planned around it** — if a plugin path has appeared, it changes the
answer.

Assuming it has not, there are two honest paths and TVMV takes both:

- **Short term:** items 1–4 above. Thumbnails make markdown files recognisable
  in Sushi's own grid, and the context menu gives a one-click route to a real
  preview. Space itself stays Sushi's.
- **Long term:** contribute a markdown viewer upstream to gnome-sushi. Sushi
  already ships a WebKit-based HTML viewer, so a viewer that renders markdown
  through a converter into that same view is a plausible contribution rather
  than a fork. This is tracked as upstream work on GNOME's release cadence, not
  as a TVMV deliverable — nothing in TVMV's own schedule should depend on it.

Shipping a patched Sushi is explicitly rejected: it would overwrite a
system package, break on upgrade, and is not something to ask users to install.

### The WebKit sandbox needs an AppArmor profile on Ubuntu 24.04

WebKitGTK confines web processes with bubblewrap, which needs an unprivileged
user namespace. Ubuntu 24.04 sets
`kernel.apparmor_restrict_unprivileged_userns=1`, denying that to **unconfined**
processes — so an uninstalled build aborts at launch:

```text
bwrap: setting up uid map: Permission denied
ERROR: Failed to fully launch dbus-proxy
Trace/breakpoint trap
```

Packaged WebKit apps avoid it with a one-line profile granting `userns`; Ubuntu
ships exactly that for `epiphany`, `chrome` and `flatpak`.
`linux/data/apparmor/tvmv` is modelled on it and installs to `/etc/apparmor.d/`.

A build run straight out of `target/` can never have a profile, so
`startup::apply_opt_out` reads the kernel's policy — the two sysctls plus this
process's AppArmor label — and disables the WebKit sandbox with a message naming
the fix, rather than crashing.

An earlier version refused to auto-detect this, reasoning that a wrong guess
would silently weaken a security boundary. That was right about *heuristics* and
wrong here: those three files state deterministically whether bwrap can start,
and the alternative was not a slightly less safe app but one that would not run
at all. `TVMV_DISABLE_SANDBOX=1` remains as an explicit override.

## Distribution

**A native install is the primary artefact**, not the Flatpak. That reverses the
original plan, on evidence:

- **It is faster here.** Native measures 60 fps at ~0% UI-process CPU; the
  Flatpak managed 41 fps and 3-4.5 cores on the same machine. The
  `WEBKIT_FORCE_DMABUF_RENDERER` fix works in both, so the Flatpak's only
  remaining advantage — an unpatched WebKit — is no longer needed.
- **Flatpak apps look imported.** They pick up the runtime's theming rather than
  the desktop's; the cursor theme is the visible one (the sandbox has only
  Adwaita, so a host using Yaru at size 24 gets a mis-scaled pointer at 2x).
  That is precisely the "looks out of place" failure this design set out to
  avoid.

`build/linux.fish` installs binary, web assets, desktop entry, hicolor icons and
the AppArmor profile, asks for root only where the prefix actually needs it, and
has a symmetric `uninstall`. `PREFIX` defaults to `/usr/local`.

The Flatpak manifest stays for people who prefer it and for distros with an old
WebKitGTK, but it is no longer the recommended path, and its cursor-theme gap
(host icon themes are not visible in the sandbox) is unfixed.

`.deb` and AppImage remain deferred.

## Keeping the three projects from colliding

| Axis | macOS / iOS | Linux | Status |
|---|---|---|---|
| Shell source | `Sources/`, `ios/` | `linux/` | No overlap; mirrors the existing `ios/` convention |
| Build output | `.build/`, `dist/`, `DerivedData/` | `linux/target/` | Distinct; all gitignored |
| Build scripts | `build/{bundle,ios,release,quicklook,signing}.fish` | `build/linux.fish`, `build/sync-web.fish` | Distinct filenames in a shared dir |
| Web layer | consumes generated copy | consumes `web/` directly | **The only real risk — see below** |
| Markdown engine | `swift-cmark` @ rev `0101bf2c` via SwiftPM | same rev via `linux/vendor/swift-cmark` submodule | Identical source by construction; `vendor_pin.rs` fails if either side is bumped alone |
| App identity | `dk.dyregod.tvmv`, `.ios` | `dk.dyregod.tvmv` (desktop / D-Bus / Flatpak) | Separate namespaces; no conflict |
| Settings store | `UserDefaults` | `$XDG_CONFIG_HOME/tvmv/settings.toml` | No shared storage. Key names and semantics are mirrored so `styleJSON` is identical |
| `tvmv` CLI | `~/.local/bin/tvmv` shim | `/usr/bin/tvmv` or Flatpak alias | Collides only on a `$HOME` shared between a Mac and a Linux box over NFS — documented, not defended against |
| `tvmv-asset://` scheme | same on both | same on both | Intentional sharing, not a collision |
| Test suites | XCTest (needs Xcode) | `cargo test` | Independent runners; shared fixtures from `Fixtures/` |

### The web-layer promotion, in detail

This is the one change that touches the working Mac and iOS builds, so it is
designed to fail loudly rather than silently.

`web/` becomes canonical via `git mv Sources/TVMVCore/Resources/web web` — a
clean rename of 74 tracked files that git records as renames, preserving
history. `vendor.fish` resolves paths relative to its own directory, so it
keeps working unchanged after the move.

SwiftPM requires resources to live under the target directory, so
`Sources/TVMVCore/Resources/web/` must still exist at build time. Two options,
in preference order:

1. **Symlink** `Sources/TVMVCore/Resources/web -> ../../../web`. Least
   friction if SwiftPM's `.copy()` follows it. **This must be verified on the
   Mac** — it cannot be tested from a Linux box, and behavior has varied across
   SwiftPM versions.
2. **Generated copy** via `build/sync-web.fish`, gitignored, wired into
   `bundle.fish` and `ios.fish`.

Option 2's hazard is that the README documents running `swift test` directly,
which would then run against a missing or stale copy. Mitigation: a Swift test
that fails with an explicit "run `fish build/sync-web.fish`" message when the
copy is absent or older than `web/`. `Package.swift` itself does not change —
the resource path stays `Resources/web` either way.

### Shared golden tests

A fixture markdown corpus under `Fixtures/` renders to expected HTML, and
**both** test suites assert against the same expected output — XCTest on macOS,
`cargo test` on Linux. This is what converts cmark-gfm version skew and web-layer
drift from a bug report into a build failure. CI runs a macOS job and a Linux
job; both run the golden test.

## Out of scope for v1

- `.deb` and AppImage packaging
- The upstream gnome-sushi markdown viewer (contributed separately, on GNOME's
  cadence; no TVMV milestone depends on it)
- Wayland-specific window features beyond what GTK4 provides by default
- Touching the Mac or iOS shells beyond the web-layer path change

## Verification constraint

There is no Swift toolchain on the Linux development machine. Anything touching
`web/`, `Package.swift`, or the resource path must be gated on the Mac before
it lands. The Linux work itself is fully verifiable locally: `libwebkitgtk-6.0-dev`
2.52.3 and `libgtk-4-dev` 4.14.5 are in Ubuntu 24.04's archive, `cargo`/`rustc`
are installed, and the markdown engine needs no system package at all.

The renderer, the golden corpus, and the pin guard were built and verified on
Linux with no Mac involved — see `Fixtures/golden/README.md` for why the
expectations are trustworthy without one.
