# Golden rendering fixtures

`<name>.md` renders to `<name>.html` (plain) and `<name>.sourcepos.html`
(`CMARK_OPT_SOURCEPOS`). Both the Rust suite (`linux/tests/golden.rs`) and the
Swift suite (`Tests/TVMVCoreTests/GoldenRenderTests.swift`) assert against these
same files, byte for byte. `showcase.md` one directory up is part of the corpus.

## Provenance

The expectations were generated on Linux by `linux/`, which compiles
`linux/vendor/swift-cmark` — the *same* cmark-gfm revision the Mac resolves
through `Package.resolved`. Because both shells compile identical C source with
identical options and the same four extensions in the same order, these files
are the Mac's output by construction. The Swift suite confirms that rather than
defining it, which is why the corpus could be built without a Mac present.

`linux/tests/vendor_pin.rs` fails if the submodule and `Package.resolved` ever
name different revisions.

## Regenerating

Only when cmark-gfm is intentionally re-pinned — never to make a red test green:

```sh
cargo build --release --manifest-path linux/Cargo.toml
for f in Fixtures/golden/*.md Fixtures/showcase.md
    set b (basename $f .md)
    ./linux/target/release/tvmv $f > Fixtures/golden/$b.html
    ./linux/target/release/tvmv $f --source-pos > Fixtures/golden/$b.sourcepos.html
end
```

Then re-run the Swift suite on the Mac before landing.

## Coverage

| Fixture | Exercises |
|---|---|
| `extensions.md` | all four GFM extensions, alone and combined |
| `nesting.md` | quotes/lists/fences nested so source positions are non-obvious |
| `code-math-mermaid.md` | fences the web layer post-processes; unclosed fence |
| `edge.md` | setext headings, hard breaks, entities, Unicode, escapes, empty cells |
| `showcase.md` | the document the app ships as its own demo |
