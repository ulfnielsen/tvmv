# Heading with {==a comment==}[^rv-h1h1] and {~~old~>new~~}[^rv-h2h2]

The {==cache is invalidated on every save==}[^rv-k3f9] and the index is
{~~rebuilt lazily~>rebuilt eagerly on open~~}[^rv-p2x7] from disk.
{++Autosave writes are exempt.++}[^rv-p2x7] A point comment.[^rv-z9y8]

*Emphasis around {==an anchor==}[^rv-k3f9]* and {--a deletion--}[^rv-d4d4].

- A list item with a point.[^rv-z9y8]
- `{==code is literal==}[^rv-k3f9]`

A dangling {==anchor==}[^rv-gone] stays marked.

[^rv-k3f9]: @ulf 2026-10-14: True for autosave too?
    @claude 2026-10-14: No, see the added sentence.
[^rv-p2x7]: @claude 2026-10-14 suggestion: Eager rebuild avoids the first-scroll stall.
[^rv-z9y8]: @ulf 2026-10-14: Needs a source.
[^rv-h1h1]: @ulf 2026-10-14: Title comment.
[^rv-h2h2]: @ulf 2026-10-14 suggestion: Rename.
[^rv-d4d4]: @ulf 2026-10-14 suggestion: Drop it.
[^rv-orph]: @ulf 2026-10-14: An orphan thread.
