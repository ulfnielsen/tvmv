//! Golden layout tests: the gate that holds `layout.rs` to the Swift
//! `MarkdownLayoutParser` it ports.
//!
//! Every fixture's layout is described as JSON with UTF-16 offsets, the unit
//! the Swift side counts in, and compared against `Fixtures/layout/<name>.json`.
//! `Tests/TVMVCoreTests/GoldenLayoutTests.swift` asserts the same files with
//! the same description. See `Fixtures/layout/README.md`.
//!
//! Regenerate (only when the layout intentionally changes on both sides):
//! `TVMV_UPDATE_LAYOUT_GOLDEN=1 cargo test --test layout_golden`.

use std::ops::Range;
use std::path::PathBuf;

use serde_json::{Value, json};
use tvmv::layout::{Alignment, Layout, Style, parse};
use tvmv::review_spans::SpanRole;

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../Fixtures")
}

/// Every Markdown fixture: the showcase, the HTML corpus, and the layout corpus.
fn cases() -> Vec<(String, PathBuf)> {
    let mut cases = vec![("showcase".to_string(), fixtures().join("showcase.md"))];
    for dir in ["golden", "layout"] {
        for entry in std::fs::read_dir(fixtures().join(dir)).expect("fixture directory is readable") {
            let path = entry.expect("dir entry").path();
            let stem = path.file_stem().unwrap().to_string_lossy().into_owned();
            if path.extension().and_then(|e| e.to_str()) == Some("md") && stem != "README" {
                cases.push((stem, path));
            }
        }
    }
    cases.sort();
    cases
}

/// Byte offset -> UTF-16 offset.
struct Utf16(Vec<usize>);

impl Utf16 {
    fn new(text: &str) -> Utf16 {
        let mut map = vec![0; text.len() + 1];
        let mut units = 0;
        for (i, c) in text.char_indices() {
            map[i..i + c.len_utf8()].iter_mut().for_each(|m| *m = units);
            units += c.len_utf16();
        }
        map[text.len()] = units;
        Utf16(map)
    }

    fn at(&self, byte: usize) -> usize {
        self.0[byte]
    }

    /// `location+length`, as `NSRange` would print it.
    fn r(&self, r: &Range<usize>) -> String {
        let start = self.at(r.start);
        format!("{start}+{}", self.at(r.end) - start)
    }
}

/// Swift's `"\(role)"`.
fn role(role: SpanRole) -> &'static str {
    match role {
        SpanRole::Delimiter => "delimiter",
        SpanRole::Ref => "ref",
        SpanRole::Highlight => "highlight",
        SpanRole::Insertion => "insertion",
        SpanRole::Deletion => "deletion",
        SpanRole::SubstitutionOld => "substitutionOld",
        SpanRole::SubstitutionNew => "substitutionNew",
        SpanRole::PointMarker => "pointMarker",
        SpanRole::Definition => "definition",
    }
}

fn style(style: &Style) -> String {
    match style {
        Style::Emphasis => "emphasis".into(),
        Style::Strong => "strong".into(),
        Style::Strikethrough => "strikethrough".into(),
        Style::Code => "code".into(),
        Style::Link { url } => format!("link({url})"),
        Style::Autolink { url } => format!("autolink({url})"),
        Style::Heading { level } => format!("heading({level})"),
        Style::CodeBlock { language } => format!("codeBlock({})", language.as_deref().unwrap_or("")),
        Style::Html => "html".into(),
        Style::Image => "image".into(),
        Style::Review { role: r, id } => format!("review({},{id})", role(*r)),
    }
}

fn alignment(a: Alignment) -> &'static str {
    match a {
        Alignment::None => "none",
        Alignment::Left => "left",
        Alignment::Right => "right",
        Alignment::Center => "center",
    }
}

/// The description both suites produce. Keep in step with
/// `GoldenLayoutTests.describe`.
fn describe(layout: &Layout, text: &str) -> Value {
    let u = Utf16::new(text);
    json!({
        "length": u.at(layout.length),
        "styles": layout.styles.iter().map(|s| format!("{} {}", u.r(&s.range), style(&s.style))).collect::<Vec<_>>(),
        "markers": layout.markers.iter().map(|m| {
            format!("{} {}{}", u.r(&m.range), u.r(&m.unit), if m.collapses_line { " line" } else { "" })
        }).collect::<Vec<_>>(),
        "spellExempt": layout.spell_exempt.iter().map(|r| u.r(r)).collect::<Vec<_>>(),
        "codeBlocks": layout.code_blocks.iter().map(|c| format!("{} {}", u.r(&c.range), u.r(&c.body))).collect::<Vec<_>>(),
        "headings": layout.headings.iter().map(|h| format!("{} {} {}", h.level, u.r(&h.range), h.title)).collect::<Vec<_>>(),
        "blocks": layout.blocks.iter().map(|b| format!("{} {}", u.r(&b.range), b.kind)).collect::<Vec<_>>(),
        "softBreaks": layout.soft_breaks.iter().map(|&b| u.at(b).to_string()).collect::<Vec<_>>(),
        "listItems": layout.list_items.iter().map(|l| {
            format!(
                "{} {} {} {} {} {}",
                u.r(&l.marker),
                u.r(&l.bullet),
                l.level,
                if l.ordered { "ordered" } else { "bullet" },
                match l.task { None => "-", Some(false) => "todo", Some(true) => "done" },
                l.checkbox.as_ref().map_or("-".to_string(), |c| u.r(c)),
            )
        }).collect::<Vec<_>>(),
        "quoteLines": layout.quote_lines.iter().map(|q| format!("{} {}", u.r(&q.prefix), q.level)).collect::<Vec<_>>(),
        "tables": layout.tables.iter().map(|t| {
            let aligns: Vec<&str> = t.alignments.iter().map(|&a| alignment(a)).collect();
            let rows: Vec<String> = t.rows.iter().map(|row| row.iter().map(|c| u.r(c)).collect::<Vec<_>>().join(" ")).collect();
            format!("{} {} {}", u.r(&t.range), aligns.join(","), rows.join(" / "))
        }).collect::<Vec<_>>(),
        "blockImages": layout.block_images.iter().map(|i| format!("{} {} {}", u.r(&i.range), i.url, i.alt)).collect::<Vec<_>>(),
        "definitions": layout.definitions.iter().map(|d| format!("{} {}", u.r(&d.range), d.text)).collect::<Vec<_>>(),
    })
}

#[test]
fn layouts_match_the_corpus() {
    let update = std::env::var_os("TVMV_UPDATE_LAYOUT_GOLDEN").is_some();
    let mut failures = Vec::new();
    for (name, path) in cases() {
        let text = std::fs::read_to_string(&path).unwrap();
        let actual = describe(&parse(&text), &text);
        let expected_path = fixtures().join("layout").join(format!("{name}.json"));
        if update {
            let mut json = serde_json::to_string_pretty(&actual).unwrap();
            json.push('\n');
            std::fs::write(&expected_path, json).unwrap();
            continue;
        }
        let expected: Value = serde_json::from_str(
            &std::fs::read_to_string(&expected_path)
                .unwrap_or_else(|e| panic!("{}: {e}; regenerate with TVMV_UPDATE_LAYOUT_GOLDEN=1", expected_path.display())),
        )
        .unwrap();
        for (key, value) in actual.as_object().unwrap() {
            if expected.get(key) != Some(value) {
                let first = match (value, expected.get(key)) {
                    (Value::Array(a), Some(Value::Array(e))) => {
                        let i = a.iter().zip(e).position(|(x, y)| x != y).unwrap_or(a.len().min(e.len()));
                        format!("first difference at [{i}]: expected {:?}, actual {:?}", e.get(i), a.get(i))
                    }
                    (a, e) => format!("expected {e:?}, actual {a}"),
                };
                failures.push(format!("{name}.{key}: {first}"));
            }
        }
    }
    assert!(failures.is_empty(), "layout golden mismatch:\n{}", failures.join("\n"));
}
