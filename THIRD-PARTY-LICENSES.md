# Third-party licenses

## Vendored web assets

In `Sources/TVMVCore/Resources/web/vendor/`, for fully offline rendering. Shared
by the macOS, iOS and Linux apps.

- highlight.js 11.11.1 — BSD-3-Clause — https://github.com/highlightjs/highlight.js
- KaTeX 0.16.22 — MIT — https://github.com/KaTeX/KaTeX
- Mermaid 11.15.0 — MIT — https://github.com/mermaid-js/mermaid
- CodeMirror 6 — MIT — https://github.com/codemirror

## Markdown parser

apple/swift-cmark (cmark-gfm) — BSD-2-Clause + MIT.

Resolved through SwiftPM on Apple platforms and vendored as the
`linux/vendor/swift-cmark` submodule on Linux, pinned to the **same revision**
so both emit byte-identical HTML.

## Linux shell

Rust crates, all MIT or Apache-2.0, resolved by Cargo; see `linux/Cargo.toml`.
The GTK4 and WebKitGTK libraries themselves are LGPL and used unmodified as
system libraries, not vendored.

`linux/data/apparmor/tvmv` is modelled on Ubuntu's `/etc/apparmor.d/epiphany`.
