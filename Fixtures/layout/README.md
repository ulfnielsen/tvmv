# Golden layout fixtures

`<name>.json` describes the native editor's layout of `<name>.md`: what is
styled, what is hidden, what reveals together, and the blocks the view draws.
The inputs are every Markdown fixture: `../showcase.md`, `../golden/*.md`, and
the `*.md` files here, which target the source positions cmark gets wrong.

Both parsers assert these files with the same description, in UTF-16 offsets
(`location+length`):

- Swift: `Tests/TVMVCoreTests/GoldenLayoutTests.swift`, over `MarkdownLayoutParser`.
- Rust: `linux/tests/layout_golden.rs`, over `linux/src/layout.rs`, its port.

## Provenance

The expectations were generated on Linux by the Rust port, because the Linux
machine has no Swift toolchain. Unlike the HTML corpus, they are not right by
construction: `layout.rs` is a hand port. **The Swift parser is the
reference.** Run the Swift suite on the Mac whenever these files change. If it
disagrees, fix `layout.rs` and regenerate. Never edit the Swift parser to
match.

## Regenerating

```sh
TVMV_UPDATE_LAYOUT_GOLDEN=1 cargo test --manifest-path linux/Cargo.toml --test layout_golden
```

Do this only when the layout changes on both sides, then run the Swift suite
on the Mac before landing.
