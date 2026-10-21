//! Review markup in `render_html`: anchors become `<mark>`, `<ins>` and
//! `<del>` carrying `data-rv`, and `rv-` threads render as GFM footnotes.
//!
//! Mirrors `Tests/TVMVCoreTests/ReviewMarkupRenderTests.swift` assertion for
//! assertion, so the two renderers stay in step on review markup.

use tvmv::render::render_html;

const SPEC_EXAMPLE: &str = "\
The {==cache is invalidated on every save==}[^rv-k3f9] and the index is
{~~rebuilt lazily~>rebuilt eagerly on open~~}[^rv-p2x7] from disk.
{++Autosave writes are exempt.++}[^rv-p2x7] A point comment.[^rv-z9y8]

[^rv-k3f9]: @ulf 2026-10-14: True for autosave too?
    @claude 2026-10-14: No, see the added sentence.
[^rv-p2x7]: @claude 2026-10-14 suggestion: Eager rebuild avoids the first-scroll stall.
[^rv-z9y8]: @ulf 2026-10-14: Needs a source.
";

fn reference(id: &str, n: usize) -> String {
    format!(
        "<sup class=\"footnote-ref\"><a href=\"#fn-{id}\" id=\"fnref-{id}\" data-footnote-ref>{n}</a></sup>"
    )
}

#[test]
fn footnotes_are_enabled() {
    let html = render_html("Text[^1].\n\n[^1]: Note.\n", false);
    assert!(html.contains(&reference("1", 1)), "{html}");
    assert!(html.contains("<section class=\"footnotes\" data-footnotes>"), "{html}");
}

/// Snapshot of the spec's example, every anchor kind plus threads.
#[test]
fn spec_example_snapshot() {
    let expected = format!(
        r##"<p>The <mark data-rv="rv-k3f9">cache is invalidated on every save</mark>{} and the index is
<del data-rv="rv-p2x7">rebuilt lazily</del><ins data-rv="rv-p2x7">rebuilt eagerly on open</ins>{} from disk.
<ins data-rv="rv-p2x7">Autosave writes are exempt.</ins><sup class="footnote-ref"><a href="#fn-rv-p2x7" id="fnref-rv-p2x7-2" data-footnote-ref>2</a></sup> A point comment.{}</p>
<section class="footnotes" data-footnotes>
<ol>
<li id="fn-rv-k3f9">
<p>@ulf 2026-10-14: True for autosave too?<br />
@claude 2026-10-14: No, see the added sentence. <a href="#fnref-rv-k3f9" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="1" aria-label="Back to reference 1">↩</a></p>
</li>
<li id="fn-rv-p2x7">
<p>@claude 2026-10-14 suggestion: Eager rebuild avoids the first-scroll stall. <a href="#fnref-rv-p2x7" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="2" aria-label="Back to reference 2">↩</a> <a href="#fnref-rv-p2x7-2" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="2-2" aria-label="Back to reference 2-2">↩<sup class="footnote-ref">2</sup></a></p>
</li>
<li id="fn-rv-z9y8">
<p>@ulf 2026-10-14: Needs a source. <a href="#fnref-rv-z9y8" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="3" aria-label="Back to reference 3">↩</a></p>
</li>
</ol>
</section>
"##,
        reference("rv-k3f9", 1),
        reference("rv-p2x7", 2),
        reference("rv-z9y8", 3),
    );
    assert_eq!(render_html(SPEC_EXAMPLE, false), expected);
}

#[test]
fn deletion() {
    let html = render_html("Keep {--this--}[^rv-aaaa].\n\n[^rv-aaaa]: @x 2026-10-14 suggestion: y\n", false);
    let expected = format!("<p>Keep <del data-rv=\"rv-aaaa\">this</del>{}.</p>", reference("rv-aaaa", 1));
    assert!(html.contains(&expected), "{html}");
}

#[test]
fn inline_formatting_inside_anchors() {
    let html = render_html("{==*very* `x`==}[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-14: y\n", false);
    assert!(html.contains("<mark data-rv=\"rv-aaaa\"><em>very</em> <code>x</code></mark>"), "{html}");
}

/// The substitution's `~~` must not be read as GFM strikethrough.
#[test]
fn substitution_is_not_strikethrough() {
    let html = render_html("{~~a~>b~~}[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-14 suggestion: y\n", false);
    assert!(html.contains("<del data-rv=\"rv-aaaa\">a</del><ins data-rv=\"rv-aaaa\">b</ins>"), "{html}");
    assert!(!html.contains('~'), "{html}");
}

#[test]
fn dangling_anchor_still_marks_its_text() {
    let html = render_html("See {==this==}[^rv-aaaa].\n", false);
    assert!(html.contains("<p>See <mark data-rv=\"rv-aaaa\">this</mark>[^rv-aaaa].</p>"), "{html}");
}

#[test]
fn bare_markup_and_code_are_left_alone() {
    let markdown = "Plain {==x==} here and `{==y==}[^rv-aaaa]` there.\n\n```\n{++z++}[^rv-aaaa]\n```\n";
    assert_eq!(
        render_html(markdown, false),
        "<p>Plain {==x==} here and <code>{==y==}[^rv-aaaa]</code> there.</p>\n\
         <pre><code>{++z++}[^rv-aaaa]\n</code></pre>\n"
    );
}

/// Markup inside an attribute (an image's alt text) cannot become tags; it
/// falls back to its literal delimiters.
#[test]
fn markup_inside_attribute_stays_text() {
    let html = render_html("![a {==b==}[^rv-aaaa]](i.png)\n\n[^rv-aaaa]: @x 2026-10-14: y\n", false);
    assert!(html.contains("alt=\"a {==b==}\""), "{html}");
    assert!(!html.contains("<mark"), "{html}");
    assert!(!html.chars().any(|c| ('\u{E000}'..='\u{E0FF}').contains(&c) || c == '\u{80}'), "{html}");
}

/// A document that already contains a sentinel character renders as plain
/// Markdown rather than having it misread as review markup.
#[test]
fn source_containing_sentinels_skips_review_rendering() {
    let html = render_html("\u{E001} {==x==}[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-14: y\n", false);
    assert!(html.contains("\u{E001} {==x==}"), "{html}");
    assert!(!html.contains("<mark"), "{html}");
}

/// The pre-pass keeps every line's byte length, so `data-sourcepos` columns
/// match the file as written.
#[test]
fn source_positions_are_unchanged() {
    let first_line = "A {==b==}[^rv-aaaa] {~~c~>d~~}[^rv-bbbb] {++e++}[^rv-aaaa] {--f--}[^rv-aaaa]";
    let markdown = format!(
        "{first_line}\n\nnext\n\n[^rv-aaaa]: @x 2026-10-14: y\n[^rv-bbbb]: @x 2026-10-14 suggestion: z\n"
    );
    let html = render_html(&markdown, true);
    assert!(html.contains(&format!("<p data-sourcepos=\"1:1-1:{}\">", first_line.len())), "{html}");
    assert!(html.contains("<p data-sourcepos=\"3:1-3:4\">next</p>"), "{html}");
}

/// Without review markup the pass is skipped entirely: output is plain
/// cmark-gfm with footnotes on.
#[test]
fn documents_without_review_markup_are_untouched() {
    assert_eq!(
        render_html("# T\n\n{==not review==} and ~~strike~~\n", false),
        "<h1>T</h1>\n<p>{==not review==} and <del>strike</del></p>\n"
    );
}
