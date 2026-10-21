//! The native editor's layout: what hides, what is styled, what reveals
//! together.
//!
//! Mirrors `Tests/TVMVCoreTests/MarkdownLayoutParserTests.swift` and
//! `ReviewLayoutTests.swift` assertion for assertion, so the two parsers stay
//! in step.

use std::time::Instant;

use tvmv::layout::{Alignment, Layout, Style, encloses, may_have_review_markup, parse};
use tvmv::review::AnchorKind;
use tvmv::review_spans::SpanRole;

/// The text each marker hides, in source order.
fn hidden(text: &str) -> Vec<&str> {
    let mut markers = parse(text).markers;
    markers.sort_by_key(|m| m.range.start);
    markers.into_iter().map(|m| &text[m.range]).collect()
}

/// The text of every style run matching `matches`, in source order.
fn styled(text: &str, matches: impl Fn(&Style) -> bool) -> Vec<&str> {
    let mut styles = parse(text).styles;
    styles.retain(|s| matches(&s.style));
    styles.sort_by_key(|s| s.range.start);
    styles.into_iter().map(|s| &text[s.range]).collect()
}

fn review_styled(text: &str, role: SpanRole) -> Vec<&str> {
    parse(text)
        .styles
        .into_iter()
        .filter(|s| matches!(&s.style, Style::Review { role: r, .. } if *r == role))
        .map(|s| &text[s.range])
        .collect()
}

#[test]
fn emphasis_strong_and_strikethrough_hide_only_their_delimiters() {
    let text = "a **b** _c_ ~~d~~ ***e***\n";
    assert_eq!(hidden(text), ["**", "**", "_", "_", "~~", "~~", "*", "**", "**", "*"]);
    assert_eq!(styled(text, |s| *s == Style::Strong), ["b", "e"]);
    assert_eq!(styled(text, |s| *s == Style::Emphasis), ["c", "**e**"]);
    assert_eq!(styled(text, |s| *s == Style::Strikethrough), ["d"]);
}

#[test]
fn atx_heading_hides_prefix_and_closing_hashes() {
    let text = "## Title *x* ##\n";
    assert_eq!(hidden(text), ["## ", "*", "*", " ##"]);
    let layout = parse(text);
    assert_eq!(layout.headings.iter().map(|h| h.level).collect::<Vec<_>>(), [2]);
    assert_eq!(layout.headings.iter().map(|h| h.title.as_str()).collect::<Vec<_>>(), ["Title x"]);
}

#[test]
fn setext_underline_collapses() {
    let text = "Title\n=====\n\nbody\n";
    let layout = parse(text);
    assert_eq!(hidden(text), ["=====\n"]);
    assert_eq!(layout.markers.iter().map(|m| m.collapses_line).collect::<Vec<_>>(), [true]);
    assert_eq!(layout.headings.iter().map(|h| h.title.as_str()).collect::<Vec<_>>(), ["Title"]);
}

#[test]
fn fenced_code_collapses_fences_and_keeps_the_body() {
    let text = "```swift\nlet x = 1\n```\nafter\n";
    let layout = parse(text);
    assert_eq!(hidden(text), ["```swift\n", "```\n"]);
    assert_eq!(layout.markers.iter().map(|m| m.collapses_line).collect::<Vec<_>>(), [true, true]);
    assert_eq!(layout.code_blocks.iter().map(|c| &text[c.body.clone()]).collect::<Vec<_>>(), ["let x = 1"]);
    assert!(layout.styles.iter().any(|s| s.style == Style::CodeBlock { language: Some("swift".into()) }));
}

#[test]
fn unclosed_fence_hides_only_the_opening_line() {
    assert_eq!(hidden("```\nstill open\n"), ["```\n"]);
    // A last line that starts with backticks but carries an info string can't
    // close a fence; it is code and must stay visible.
    assert_eq!(hidden("Intro\n\n```\nsome code\n```python\n"), ["```\n"]);
}

#[test]
fn code_spans_hide_their_backtick_runs() {
    assert_eq!(hidden("a `c` b\n"), ["`", "`"]);
    assert_eq!(hidden("a `` x`y `` b\n"), ["``", "``"]);
}

#[test]
fn links_and_autolinks() {
    let text = "[text](http://a.b \"t\") [ref][r] <http://c.d> www.e.com\n\n[r]: http://r.s\n";
    assert_eq!(hidden(text), ["[", "](http://a.b \"t\")", "[", "][r]", "<", ">"]);
    let layout = parse(text);
    let links: Vec<String> = layout
        .styles
        .iter()
        .filter_map(|run| match &run.style {
            Style::Link { url } | Style::Autolink { url } => Some(format!("{} -> {url}", &text[run.range.clone()])),
            _ => None,
        })
        .collect();
    assert_eq!(
        links,
        ["text -> http://a.b", "ref -> http://r.s", "http://c.d -> http://c.d", "www.e.com -> http://www.e.com"]
    );
    assert_eq!(layout.definitions.iter().map(|d| d.text.as_str()).collect::<Vec<_>>(), ["[r]: http://r.s"]);
}

#[test]
fn hard_line_breaks_do_not_shift_later_positions() {
    // cmark's own inline positions are wrong after a hard break.
    let text = "a\\\nb *c* d  \ne **f**\n";
    assert_eq!(hidden(text), ["*", "*", "**", "**"]);
    assert_eq!(styled(text, |s| *s == Style::Emphasis), ["c"]);
    assert_eq!(styled(text, |s| *s == Style::Strong), ["f"]);
}

#[test]
fn astral_and_cjk_characters_keep_offsets_aligned() {
    let text = "é😀*x* 日本 **語**\n";
    assert_eq!(hidden(text), ["*", "*", "**", "**"]);
    assert_eq!(styled(text, |s| *s == Style::Emphasis), ["x"]);
    assert_eq!(styled(text, |s| *s == Style::Strong), ["語"]);
}

#[test]
fn inline_positions_inside_quotes_lists_and_tables() {
    let text = "> quote *q*\n\n- item **one**\n- [ ] task `c`\n\n| A | *B* |\n|---|---|\n| 1 | `2` |\n";
    assert_eq!(hidden(text), ["*", "*", "**", "**", "`", "`", "*", "*", "`", "`"]);
}

#[test]
fn spell_exemptions() {
    let text = "see `wrongg` and [l](http://wrongg.x)\n";
    let exempt: Vec<&str> = parse(text).spell_exempt.into_iter().map(|r| &text[r]).collect();
    assert_eq!(exempt, ["`wrongg`", "](http://wrongg.x)"]);
}

#[test]
fn empty_and_markup_free_documents() {
    assert!(parse("").markers.is_empty());
    assert!(parse("plain words").markers.is_empty());
    assert_eq!(parse("plain words").length, 11);
}

#[test]
fn soft_line_breaks_inside_paragraphs_are_recorded() {
    let text = "one\ntwo\nthree\n\nhard\\\nnext  \nlast\n\n```\na\nb\n```\n\n- x\n  y\n\n> q\n> r\n";
    let breaks = parse(text).soft_breaks;
    let line_after: Vec<&str> = breaks
        .iter()
        .map(|&b| {
            let start = b + 1;
            let end = text[start..].find('\n').map_or(text.len(), |i| start + i + 1);
            &text[start..end]
        })
        .collect();
    assert_eq!(line_after, ["two\n", "three\n"]);
    assert!(breaks.iter().all(|&b| text.as_bytes()[b] == b'\n'));
}

#[test]
fn an_image_alone_in_its_paragraph_is_a_block_image() {
    let text = "Intro.\n\n![A chart](img/chart.png \"Title\")\n\nText with ![inline](x.png) inside.\n\n![remote](https://e.x/p.png)\n";
    let images = parse(text).block_images;
    assert_eq!(
        images.iter().map(|i| &text[i.range.clone()]).collect::<Vec<_>>(),
        ["![A chart](img/chart.png \"Title\")", "![remote](https://e.x/p.png)"]
    );
    assert_eq!(images.iter().map(|i| i.url.as_str()).collect::<Vec<_>>(), ["img/chart.png", "https://e.x/p.png"]);
    assert_eq!(images.iter().map(|i| i.alt.as_str()).collect::<Vec<_>>(), ["A chart", "remote"]);
}

#[test]
fn tables_record_their_cells_rows_and_alignment() {
    let text = "Intro.\n\n| Name | *Score* | Note |\n|:-----|------:|:---:|\n| Ada  | 10 | a \\| b |\n| Bob | 7 |  |\n\nAfter.\n";
    let tables = parse(text).tables;
    assert_eq!(tables.len(), 1);
    let table = &tables[0];
    assert_eq!(
        &text[table.range.clone()],
        "| Name | *Score* | Note |\n|:-----|------:|:---:|\n| Ada  | 10 | a \\| b |\n| Bob | 7 |  |"
    );
    assert_eq!(table.alignments, [Alignment::Left, Alignment::Right, Alignment::Center]);
    // Cell ranges cover the content only: no pipes, no padding.
    let rows: Vec<Vec<&str>> = table.rows.iter().map(|r| r.iter().map(|c| &text[c.clone()]).collect()).collect();
    assert_eq!(rows, [vec!["Name", "*Score*", "Note"], vec!["Ada", "10", "a \\| b"], vec!["Bob", "7", ""]]);
    // An empty cell is an empty range sitting between its pipes.
    let empty = &table.rows[2][2];
    assert!(empty.is_empty());
    assert_eq!(text.as_bytes()[empty.start - 1], b' ');
}

#[test]
fn list_items_record_marker_level_order_and_task_state() {
    let text = "- one\n- two\n  - nested\n\n3) third\n4) fourth\n\n- [ ] todo\n- [x] done\n";
    let items = parse(text).list_items;
    assert_eq!(
        items.iter().map(|i| &text[i.marker.clone()]).collect::<Vec<_>>(),
        ["- ", "- ", "  - ", "3) ", "4) ", "- [ ] ", "- [x] "]
    );
    assert_eq!(items.iter().map(|i| i.level).collect::<Vec<_>>(), [0, 0, 1, 0, 0, 0, 0]);
    assert_eq!(items.iter().map(|i| i.ordered).collect::<Vec<_>>(), [false, false, false, true, true, false, false]);
    assert_eq!(
        items.iter().map(|i| i.task).collect::<Vec<_>>(),
        [None, None, None, None, None, Some(false), Some(true)]
    );
    assert_eq!(
        items.iter().filter_map(|i| i.checkbox.clone()).map(|c| &text[c]).collect::<Vec<_>>(),
        ["[ ]", "[x]"]
    );
    assert_eq!(
        items.iter().map(|i| &text[i.bullet.clone()]).collect::<Vec<_>>(),
        ["-", "-", "-", "3)", "4)", "-", "-"]
    );
}

#[test]
fn quote_lines_record_their_prefix_and_level() {
    let text = "> outer\n> still\n>> inner\n\nplain\n";
    let lines = parse(text).quote_lines;
    assert_eq!(lines.iter().map(|l| &text[l.prefix.clone()]).collect::<Vec<_>>(), ["> ", "> ", ">> "]);
    assert_eq!(lines.iter().map(|l| l.level).collect::<Vec<_>>(), [1, 1, 2]);
}

#[test]
fn deeply_nested_quotes_and_lists_parse_quickly() {
    let texts = [
        ">".repeat(20_000) + " x\n",
        "- ".repeat(20_000) + "x\n",
        "*a ".repeat(20_000) + "x" + &" a*".repeat(20_000) + "\n",
        "[".repeat(20_000) + "x" + &"](u)".repeat(20_000) + "\n",
    ];
    for text in texts {
        let start = Instant::now();
        let layout = parse(&text);
        assert!(start.elapsed().as_secs_f64() < 2.0, "{:?}", start.elapsed());
        assert_eq!(layout.length, text.len());
    }
}

// MARK: Review markup (ReviewLayoutTests.swift)

const THREAD: &str = "\n\n[^rv-a1b2]: @ulf 2026-10-14: Why?\n";

#[test]
fn a_highlight_hides_its_delimiters_and_ref() {
    let text = format!("The {{==cache==}}[^rv-a1b2] is cold.{THREAD}");
    assert_eq!(hidden(&text), ["{==", "==}", "[^rv-a1b2]", "[^rv-a1b2]: @ulf 2026-10-14: Why?\n"]);
    assert_eq!(review_styled(&text, SpanRole::Highlight), ["cache"]);
}

#[test]
fn an_anchor_reveals_as_one_unit() {
    let text = format!("The {{==cache==}}[^rv-a1b2] is cold.{THREAD}");
    let layout = parse(&text);
    let start = text.find("{==cache==}[^rv-a1b2]").unwrap();
    let anchor = start..start + "{==cache==}[^rv-a1b2]".len();
    assert!(layout.markers.iter().take(3).all(|m| m.unit == anchor));
    assert!(layout.reveal_units().contains(&anchor));
}

#[test]
fn suggestions_style_each_side() {
    let text = "a {++new++}[^rv-a1b2] b {--old--}[^rv-c3d4] c {~~was~>is~~}[^rv-e5f6]\n\n\
                [^rv-a1b2]: @ulf 2026-10-14 suggestion: x\n[^rv-c3d4]: @ulf 2026-10-14 suggestion: y\n\
                [^rv-e5f6]: @ulf 2026-10-14 suggestion: z\n";
    assert_eq!(review_styled(text, SpanRole::Insertion), ["new"]);
    assert_eq!(review_styled(text, SpanRole::Deletion), ["old"]);
    assert_eq!(review_styled(text, SpanRole::SubstitutionOld), ["was"]);
    assert_eq!(review_styled(text, SpanRole::SubstitutionNew), ["is"]);
    assert_eq!(
        hidden(text)[..9],
        ["{++", "++}", "[^rv-a1b2]", "{--", "--}", "[^rv-c3d4]", "{~~", "~", "~~}"]
    );
    assert_eq!(review_styled(text, SpanRole::Delimiter), [">"], "the '>' stays as the gap between old and new");
}

#[test]
fn a_point_comment_keeps_one_character_for_its_marker() {
    let text = format!("Needs a source.[^rv-a1b2]{THREAD}");
    assert_eq!(hidden(&text)[0], "^rv-a1b2]");
    assert_eq!(review_styled(&text, SpanRole::PointMarker), ["["]);
}

#[test]
fn a_ref_is_not_a_link_and_threads_are_not_prose() {
    let text = format!("The {{==cache==}}[^rv-a1b2] is cold.{THREAD}");
    let layout = parse(&text);
    assert!(!layout.styles.iter().any(|s| matches!(s.style, Style::Link { .. })));
    let def = "[^rv-a1b2]: @ulf 2026-10-14: Why?\n";
    let start = text.find(def).unwrap();
    let definition = start..start + def.len();
    assert!(layout.markers.iter().any(|m| m.range == definition && m.collapses_line && m.unit == definition));
    assert!(layout.spell_exempt.iter().any(|r| encloses(r, &definition)));
    assert!(!layout.styles.iter().any(|s| s.range.start.max(definition.start) < s.range.end.min(definition.end)));
}

#[test]
fn a_reply_line_collapses_with_its_thread() {
    let text = "x[^rv-a1b2]\n\n[^rv-a1b2]: @ulf 2026-10-14: Why?\n    @claude 2026-10-14: *Because*.\n";
    let start = text.find("[^rv-a1b2]: @ulf").unwrap();
    let collapsed: Vec<_> = parse(text).markers.into_iter().filter(|m| m.collapses_line).map(|m| m.range).collect();
    assert_eq!(collapsed, vec![start..text.len()]);
}

#[test]
fn the_parsed_review_rides_along() {
    assert!(parse("Plain *text*.\n").review.is_none());
    let review = parse(&format!("The {{==cache==}}[^rv-a1b2] is cold.{THREAD}")).review.unwrap();
    assert_eq!(review.threads.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), ["rv-a1b2"]);
    assert_eq!(review.anchors.iter().map(|a| a.kind).collect::<Vec<_>>(), [AnchorKind::Highlight]);
}

#[test]
fn markup_in_code_stays_code() {
    let text = "`{==x==}[^rv-a1b2]`\n";
    assert_eq!(hidden(text), ["`", "`"]);
    assert!(review_styled(text, SpanRole::Highlight).is_empty());
}

#[test]
fn styles_around_an_anchor_survive() {
    // A comment inside italics, a heading or a link must not unstyle them.
    type Matcher = fn(&Style) -> bool;
    let cases: [(&str, Matcher); 4] = [
        ("*one {==two==}[^rv-a1b2] three*", |s| *s == Style::Emphasis),
        ("# Title {==two==}[^rv-a1b2]", |s| *s == Style::Heading { level: 1 }),
        ("**bold[^rv-a1b2]**", |s| *s == Style::Strong),
        ("[see {==here==}[^rv-a1b2]](http://x.y)", |s| matches!(s, Style::Link { .. })),
    ];
    for (line, matches) in cases {
        let text = format!("{line}{THREAD}");
        assert!(parse(&text).styles.iter().any(|s| matches(&s.style)), "styled: «{line}»");
    }
}

#[test]
fn heading_titles_leave_review_markup_out() {
    let layout = parse(&format!("# Title {{==two==}}[^rv-a1b2] {{~~old~>new~~}}[^rv-c3d4]\n{THREAD}"));
    assert_eq!(layout.headings.iter().map(|h| h.title.as_str()).collect::<Vec<_>>(), ["Title two new"]);
}

#[test]
fn text_without_review_markup_skips_the_review_parse() {
    assert!(!may_have_review_markup("Plain {== text ==} with [^note]."));
    assert!(may_have_review_markup("A ref.[^rv-a1b2]"));
}

// MARK: Random edits (MarkdownLayoutPropertyTests.swift)

struct Lcg(u64);

impl Lcg {
    fn next(&mut self, bound: usize) -> usize {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((self.0 >> 33) % bound.max(1) as u64) as usize
    }
}

const TOKENS: &[&str] = &[
    "*", "**", "_", "`", "``", "```\n", "~~", "# ", "## ", "\n", "\n\n", "x", "word ", "[a](b)", "[r]",
    "[r]: http://z\n", "- ", "> ", "| a |", "\\\n", "  \n", "==\n", "<http://q>", "é", "😀", " ", "1. ",
    "<div>\n", " ##", "www.q.com ", "{==", "==}", "{~~", "~>", "~~}", "{++", "--}", "[^rv-a1b2]",
    "{==x==}[^rv-a1b2]", "{~~a~>b~~}[^rv-c3d4]", "\n\n[^rv-a1b2]: @ulf 2026-10-14: *note*\n",
    "    @claude 2026-10-14: ok\n", "\n\n[^rv-c3d4]: @ulf 2026-10-14 suggestion: x\n",
];

/// Every full parse hides only markup, and `changed_range` covers every
/// styling difference between consecutive parses (it bounds the restyle, so
/// a miss is a stale style).
#[test]
fn random_edits_keep_invariants_and_diffs_sound() {
    let start = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../Fixtures/showcase.md")).unwrap();
    for seed in [1u64, 2, 3] {
        let mut rng = Lcg(seed);
        let mut text = start.clone();
        let mut layout = parse(&text);
        for step in 0..600 {
            let mut location = rng.next(text.len() + 1);
            let mut length = if rng.next(3) == 0 { rng.next(8.min(text.len() - location) + 1) } else { 0 };
            // Never split a character.
            while !text.is_char_boundary(location) {
                location -= 1;
                length = 0;
            }
            while !text.is_char_boundary((location + length).min(text.len())) {
                length += 1;
            }
            let length = length.min(text.len() - location);
            let insert = if rng.next(4) == 0 { "" } else { TOKENS[rng.next(TOKENS.len())] };
            let edit = location..location + length;
            let mut new_text = text.clone();
            new_text.replace_range(edit.clone(), insert);
            let delta = insert.len() as isize - length as isize;
            let new = parse(&new_text);
            let context = format!("seed {seed} step {step} edit {edit:?} «{insert}»");
            assert_invariants(&new, &new_text, &context);
            assert_diff_sound(&layout, &new, edit, delta, &context);
            text = new_text;
            layout = new;
        }
    }
}

fn assert_invariants(layout: &Layout, text: &str, context: &str) {
    let review = layout.review.as_ref().map(tvmv::review_spans::spans).unwrap_or_default();
    let is_review_syntax = |r: &std::ops::Range<usize>| {
        review.iter().any(|s| {
            (s.is_hidden() || matches!(s.role, SpanRole::PointMarker | SpanRole::Definition))
                && s.range.start <= r.start
                && r.end <= s.range.end
        })
    };
    let mut claimed = vec![false; text.len()];
    for marker in &layout.markers {
        assert!(marker.range.end <= text.len(), "out of bounds: {context}");
        assert!(encloses(&marker.unit, &marker.range), "marker outside its unit: {context}");
        let hidden_text = &text[marker.range.clone()];
        let is_markup = if marker.collapses_line {
            hidden_text.contains("```") || hidden_text.contains("~~~") || hidden_text.chars().all(|c| "=-\n \t".contains(c))
        } else {
            hidden_text.chars().all(|c| "*_`~#[]<> \t".contains(c))
                || hidden_text.starts_with("](")
                || hidden_text.starts_with("][")
        };
        assert!(is_markup || is_review_syntax(&marker.range), "hides non-markup «{hidden_text}»: {context}");
        assert!(!claimed[marker.range.clone()].iter().any(|&c| c), "overlapping markers: {context}");
        claimed[marker.range.clone()].iter_mut().for_each(|c| *c = true);
    }
}

/// Outside the changed range, the new layout's styles and markers must equal
/// the old ones (shifted past the edit). Old entries inside the edited text
/// went away with it.
fn assert_diff_sound(old: &Layout, new: &Layout, edit: std::ops::Range<usize>, delta: isize, context: &str) {
    let changed = new.changed_range(old, edit.clone(), delta);
    let outside = |r: &std::ops::Range<usize>| r.end <= changed.start || r.start >= changed.end;
    let survived = |r: &std::ops::Range<usize>| r.start < edit.start || r.start >= edit.end;
    let shift = |r: &std::ops::Range<usize>| {
        if r.start >= edit.end {
            r.start.wrapping_add_signed(delta)..r.end.wrapping_add_signed(delta)
        } else {
            r.clone()
        }
    };
    let new_styles: Vec<_> = new.styles.iter().filter(|s| outside(&s.range)).cloned().collect();
    let old_styles: Vec<_> = old
        .styles
        .iter()
        .filter(|s| survived(&s.range))
        .map(|s| tvmv::layout::StyleRun { range: shift(&s.range), style: s.style.clone() })
        .filter(|s| outside(&s.range))
        .collect();
    assert_eq!(new_styles, old_styles, "styles changed outside {changed:?}: {context}");

    let new_markers: Vec<_> = new.markers.iter().filter(|m| outside(&m.unit)).cloned().collect();
    let old_markers: Vec<_> = old
        .markers
        .iter()
        .filter(|m| survived(&m.unit))
        .map(|m| tvmv::layout::Marker { range: shift(&m.range), unit: shift(&m.unit), collapses_line: m.collapses_line })
        .filter(|m| outside(&m.unit))
        .collect();
    assert_eq!(new_markers, old_markers, "markers changed outside {changed:?}: {context}");
}

/// Full parse cost at 1 MB and 5 MB. Run with
/// `cargo test --release --test layout -- --ignored --nocapture`.
#[test]
#[ignore]
fn parse_speed() {
    let showcase = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../Fixtures/showcase.md")).unwrap();
    for size in [64 * 1024, 1024 * 1024, 5 * 1024 * 1024] {
        let text = showcase.repeat(size / showcase.len() + 1);
        let start = Instant::now();
        let layout = parse(&text);
        let parsed = start.elapsed();
        let edited = format!("{}*{}", &text[..text.len() / 2], &text[text.len() / 2..]);
        let new = parse(&edited);
        let start = Instant::now();
        let changed = new.changed_range(&layout, text.len() / 2..text.len() / 2, 1);
        println!("{:5} KB: parse {parsed:?}, diff {:?}, changed {changed:?}, {} markers", size / 1024, start.elapsed(), layout.markers.len());
    }
}
