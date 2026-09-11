//! The document "card" drawn for file-manager thumbnails.
//!
//! Pango and Cairo only — **never WebKit**. A file manager calls this once per
//! file across a directory, so it has to be milliseconds and must not spawn a
//! web process.
//!
//! The same drawing backs the freedesktop thumbnailer and the KDE plugin, so a
//! `.md` looks the same in Files, Dolphin and Thunar.

use gtk4::cairo;
use gtk4::pango;

use crate::theme;

/// Read at most this much of a file. A thumbnail only shows the opening, and a
/// multi-megabyte document must not be read in full to draw one.
pub const READ_LIMIT: usize = 64 * 1024;

/// What the card shows.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Summary {
    /// First heading, or the filename when the document has none.
    pub title: String,
    /// Opening prose lines, in order.
    pub lines: Vec<String>,
}

/// Pull a title and opening lines out of markdown.
///
/// Skips YAML front matter and fenced code, because neither reads as a preview
/// of the document — a card showing `---\nlayout: post` tells the user nothing.
pub fn summarize(markdown: &str, fallback_title: &str, max_lines: usize) -> Summary {
    let mut title = String::new();
    let mut lines = Vec::new();
    let mut in_fence = false;
    let mut fence: Option<String> = None;

    let mut iter = markdown.lines().peekable();

    // YAML front matter, only when it opens the very first line.
    if iter.peek().map(|l| l.trim_end()) == Some("---") {
        iter.next();
        for line in iter.by_ref() {
            let trimmed = line.trim_end();
            if trimmed == "---" || trimmed == "..." {
                break;
            }
        }
    }

    for line in iter {
        let trimmed = line.trim();

        // Fenced code: track the exact opener so an inner ``` does not close it.
        if let Some(open) = &fence {
            if trimmed.starts_with(open.as_str()) {
                in_fence = false;
                fence = None;
            }
            continue;
        }
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_fence = true;
            fence = Some(trimmed.chars().take(3).collect());
            continue;
        }
        if in_fence {
            continue;
        }

        if trimmed.is_empty() {
            continue;
        }

        // ATX heading.
        if let Some(rest) = trimmed.strip_prefix('#') {
            let heading = rest.trim_start_matches('#').trim();
            if title.is_empty() && !heading.is_empty() {
                title = heading.to_string();
            }
            continue;
        }

        // Setext heading: the *previous* line was the title.
        if !lines.is_empty()
            && title.is_empty()
            && (trimmed.chars().all(|c| c == '=') || trimmed.chars().all(|c| c == '-'))
            && trimmed.len() >= 2
        {
            title = lines.remove(lines.len() - 1);
            continue;
        }

        if lines.len() < max_lines {
            lines.push(strip_inline_markup(trimmed));
        }

        if !title.is_empty() && lines.len() >= max_lines {
            break;
        }
    }

    if title.is_empty() {
        title = fallback_title.to_string();
    }
    Summary { title, lines }
}

/// Flatten the most common inline markup, so a card shows prose rather than
/// punctuation. Deliberately crude: this is a thumbnail, not a renderer.
fn strip_inline_markup(line: &str) -> String {
    let line = strip_leading_markers(line);

    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    // Set by a closing "]" so the "(target)" that follows can be dropped. Keyed
    // off the source rather than `out`, because "]" leaves no trace in `out`.
    let mut after_link_text = false;

    while let Some(c) = chars.next() {
        match c {
            '*' | '_' | '`' | '~' => continue,
            '!' if chars.peek() == Some(&'[') => continue,
            '[' => {
                after_link_text = false;
                continue;
            }
            ']' => {
                after_link_text = true;
                continue;
            }
            // A link or image target immediately after "]": drop it, keeping the
            // link text, so "[README](docs/x.png)" reads as "README".
            '(' if after_link_text => {
                let mut depth = 1;
                for skipped in chars.by_ref() {
                    match skipped {
                        '(' => depth += 1,
                        ')' => {
                            depth -= 1;
                            if depth == 0 {
                                break;
                            }
                        }
                        _ => {}
                    }
                }
                after_link_text = false;
            }
            _ => {
                after_link_text = false;
                out.push(c);
            }
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Drop block markers that are structure rather than prose: blockquote arrows,
/// list bullets, and ordered-list numbers.
fn strip_leading_markers(line: &str) -> &str {
    let mut rest = line.trim_start();
    loop {
        let before = rest;
        rest = rest.trim_start_matches('>').trim_start();

        if let Some(after) = rest.strip_prefix("- ").or_else(|| rest.strip_prefix("* ")) {
            rest = after.trim_start();
        } else if let Some(index) = rest.find(". ") {
            // "1. item", but not "3.14 is pi" or a sentence containing ". ".
            if index > 0 && index <= 3 && rest[..index].chars().all(|c| c.is_ascii_digit()) {
                rest = rest[index + 2..].trim_start();
            }
        }

        if rest == before {
            return rest;
        }
    }
}

/// Draw the card at `size` square.
pub fn draw(summary: &Summary, size: i32, dark: bool) -> Result<cairo::ImageSurface, cairo::Error> {
    let paper = theme::paper_for(dark);
    let ink = if dark { (0.925, 0.890, 0.827) } else { (0.165, 0.094, 0.063) };

    let surface = cairo::ImageSurface::create(cairo::Format::ARgb32, size, size)?;
    let cr = cairo::Context::new(&surface)?;

    // Paper, with a hairline edge so the card reads as a page against any
    // file-manager background — light or dark.
    cr.set_source_rgb(paper.0, paper.1, paper.2);
    cr.paint()?;
    cr.set_source_rgba(ink.0, ink.1, ink.2, 0.18);
    cr.set_line_width(1.0);
    cr.rectangle(0.5, 0.5, size as f64 - 1.0, size as f64 - 1.0);
    cr.stroke()?;

    // Everything scales off the card, so 32px and 512px look like the same
    // design rather than one being a shrunken copy of the other.
    let margin = (size as f64 * 0.10).round();
    let title_size = size as f64 * 0.115;
    let body_size = size as f64 * 0.062;
    let width = size as f64 - margin * 2.0;

    let layout = pangocairo::functions::create_layout(&cr);
    layout.set_width((width * pango::SCALE as f64) as i32);
    layout.set_wrap(pango::WrapMode::WordChar);
    layout.set_ellipsize(pango::EllipsizeMode::End);

    // Title.
    cr.set_source_rgb(ink.0, ink.1, ink.2);
    cr.move_to(margin, margin);
    let mut title_font = pango::FontDescription::from_string("Serif");
    title_font.set_absolute_size(title_size * pango::SCALE as f64);
    title_font.set_weight(pango::Weight::Bold);
    layout.set_font_description(Some(&title_font));
    layout.set_height(-2); // negative = maximum line count
    layout.set_text(&summary.title);
    pangocairo::functions::show_layout(&cr, &layout);

    let (_, title_height) = layout.pixel_size();
    let mut y = margin + title_height as f64 + size as f64 * 0.045;

    // A rule under the title, matching the reading theme's heading rules.
    cr.set_source_rgba(ink.0, ink.1, ink.2, 0.22);
    cr.set_line_width((size as f64 * 0.004).max(1.0));
    cr.move_to(margin, y);
    cr.line_to(margin + width, y);
    cr.stroke()?;
    y += size as f64 * 0.04;

    // Body lines, stopping before they would spill off the card.
    let mut body_font = pango::FontDescription::from_string("Serif");
    body_font.set_absolute_size(body_size * pango::SCALE as f64);
    layout.set_font_description(Some(&body_font));
    layout.set_height(-2); // negative = maximum line count
    cr.set_source_rgba(ink.0, ink.1, ink.2, 0.78);

    for line in &summary.lines {
        layout.set_text(line);
        let (_, height) = layout.pixel_size();
        if y + height as f64 > size as f64 - margin {
            break;
        }
        cr.move_to(margin, y);
        pangocairo::functions::show_layout(&cr, &layout);
        y += height as f64 + size as f64 * 0.018;
    }

    drop(cr);
    Ok(surface)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(markdown: &str) -> Summary {
        summarize(markdown, "fallback.md", 6)
    }

    #[test]
    fn takes_the_first_atx_heading_as_the_title() {
        let out = s("# Real Title\n\nSome prose here.\n");
        assert_eq!(out.title, "Real Title");
        assert_eq!(out.lines, vec!["Some prose here."]);
    }

    #[test]
    fn handles_setext_headings() {
        let out = s("Underlined Title\n================\n\nBody text.\n");
        assert_eq!(out.title, "Underlined Title");
        assert_eq!(out.lines, vec!["Body text."]);
    }

    /// A card showing `layout: post` tells the reader nothing about the document.
    #[test]
    fn skips_yaml_front_matter() {
        let out = s("---\nlayout: post\ntitle: Ignored\n---\n\n# Actual\n\nProse.\n");
        assert_eq!(out.title, "Actual");
        assert_eq!(out.lines, vec!["Prose."]);
    }

    /// Front matter markers only count when they open the document.
    #[test]
    fn a_thematic_break_midway_is_not_front_matter() {
        let out = s("# Title\n\nBefore.\n\n---\n\nAfter.\n");
        assert_eq!(out.title, "Title");
        assert!(out.lines.contains(&"Before.".to_string()));
    }

    #[test]
    fn skips_fenced_code() {
        let out = s("# Title\n\n```rust\nfn main() {}\n```\n\nReal prose.\n");
        assert_eq!(out.lines, vec!["Real prose."]);
    }

    #[test]
    fn falls_back_to_the_filename_without_a_heading() {
        let out = s("Just prose, no heading at all.\n");
        assert_eq!(out.title, "fallback.md");
        assert_eq!(out.lines, vec!["Just prose, no heading at all."]);
    }

    #[test]
    fn strips_inline_markup() {
        let out = s("# T\n\n**Bold** and *italic* and `code` and ~~struck~~.\n");
        assert_eq!(out.lines, vec!["Bold and italic and code and struck."]);
    }

    /// Link and image targets are noise on a card: the text is the content.
    #[test]
    fn keeps_link_text_and_drops_the_target() {
        let out = s("# T\n\nSee [the README](docs/readme.md) for details.\n");
        assert_eq!(out.lines, vec!["See the README for details."]);

        let out = s("# T\n\n![TVMV rendering its own README](docs/screenshot.png)\n");
        assert_eq!(out.lines, vec!["TVMV rendering its own README"]);
    }

    /// Nested parentheses inside a link target must not end the skip early.
    #[test]
    fn handles_nested_parentheses_in_a_target() {
        let out = s("# T\n\nA [link](https://x.test/a_(b)_c) here.\n");
        assert_eq!(out.lines, vec!["A link here."]);
    }

    /// Block markers are structure, not prose.
    #[test]
    fn strips_blockquote_and_list_markers() {
        let out = s("# T\n\n> A quoted line.\n");
        assert_eq!(out.lines, vec!["A quoted line."]);

        let out = summarize("# T\n\n- first\n- second\n", "x", 6);
        assert_eq!(out.lines, vec!["first", "second"]);

        let out = summarize("# T\n\n1. one\n2. two\n", "x", 6);
        assert_eq!(out.lines, vec!["one", "two"]);

        let out = s("# T\n\n> > Deeply quoted.\n");
        assert_eq!(out.lines, vec!["Deeply quoted."]);
    }

    /// A decimal number must not be mistaken for a list marker.
    #[test]
    fn does_not_eat_decimals_or_sentences() {
        let out = s("# T\n\n3.14 is pi.\n");
        assert_eq!(out.lines, vec!["3.14 is pi."]);

        let out = s("# T\n\nOne thing. Then another.\n");
        assert_eq!(out.lines, vec!["One thing. Then another."]);
    }

    #[test]
    fn respects_the_line_limit() {
        let markdown = "# T\n\n".to_string() + &"line\n\n".repeat(50);
        assert_eq!(summarize(&markdown, "x", 4).lines.len(), 4);
    }

    /// None of these may panic — a file manager runs this over whatever is on
    /// disk, including things that are only nominally markdown.
    #[test]
    fn pathological_input_does_not_panic() {
        for input in [
            "",
            "---\n",
            "```\nunclosed fence\n",
            "#\n",
            "#####\n",
            "\u{0}\u{1}\u{2}",
            "= \n=\n",
            &"#".repeat(10_000),
            &"a\n".repeat(10_000),
        ] {
            let _ = summarize(input, "x", 6);
        }
    }

    #[test]
    fn draws_at_every_size_without_error() {
        let summary = s("# Drawing\n\nA line of prose to lay out.\n");
        for size in [16, 32, 64, 128, 256, 512] {
            assert!(draw(&summary, size, false).is_ok(), "light {size}");
            assert!(draw(&summary, size, true).is_ok(), "dark {size}");
        }
    }
}
