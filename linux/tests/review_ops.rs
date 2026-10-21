//! Golden before → operation → after cases for every review operation and
//! anchor kind, from the Swift `ReviewMarkupOperationTests`. Each case checks
//! the exact text, that the edits are ascending and non-overlapping, and that
//! the result parses with no problems.

use std::collections::HashSet;

use tvmv::review;
use tvmv::review_ops::{Byline, Edit, Ops, apply, new_id_with};

const BY: Byline = Byline { author: "ulf", date: "2026-10-14" };
const AT: Byline = Byline { author: "@ulf", date: "2026-10-14" };

fn range(needle: &str, text: &str) -> std::ops::Range<usize> {
    let at = text.find(needle).unwrap_or_else(|| panic!("{needle:?} not in {text:?}"));
    at..at + needle.len()
}

fn after(needle: &str, text: &str) -> std::ops::Range<usize> {
    let end = range(needle, text).end;
    end..end
}

fn check(name: &str, before: &str, op: impl Fn(&Ops) -> Vec<Edit>, expected: &str) {
    let o = Ops::new(before);
    let edits = op(&o);
    let mut previous = 0;
    for e in &edits {
        assert!(e.range.start >= previous && e.range.end >= e.range.start, "{name}: edits not ascending: {edits:?}");
        previous = e.range.end;
    }
    let result = apply(&edits, before).unwrap_or_else(|| panic!("{name}: edits do not apply"));
    assert_eq!(result, expected, "{name}");
    assert_eq!(review::parse(&result).problems, vec![], "{name}: the result has problems");
}

#[test]
fn golden_cases() {
    let comment = |needle: &'static str, body: &'static str| {
        move |o: &Ops| o.add_comment(range(needle, o.text), body, &BY, Some("rv-new1"))
    };
    let point = |needle: &'static str, body: &'static str| {
        move |o: &Ops| o.add_comment(after(needle, o.text), body, &AT, Some("rv-new1"))
    };
    let suggest = |needle: &'static str, replacement: &'static str, body: &'static str| {
        move |o: &Ops| o.add_suggestion(range(needle, o.text), replacement, body, &BY, Some("rv-new1"))
    };
    let insert = |needle: &'static str, replacement: &'static str| {
        move |o: &Ops| o.add_suggestion(after(needle, o.text), replacement, "Clearer.", &BY, Some("rv-new1"))
    };
    let reply = |id: &'static str, body: &'static str| move |o: &Ops| o.reply(id, body, &BY);
    check("comment on a range, first thread", "The cache is stale.\n", comment("cache", "Why?"), "The {==cache==}[^rv-new1] is stale.\n\n[^rv-new1]: @ulf 2026-10-14: Why?\n");
    check("point comment", "The cache is stale.\n", point("stale.", "Source?"), "The cache is stale.[^rv-new1]\n\n[^rv-new1]: @ulf 2026-10-14: Source?\n");
    check("comment appends after existing threads", "A {==x==}[^rv-aaaa] b.\n\n[^rv-aaaa]: @bob 2026-10-13: Hm.\n", comment("b", "Why?"), "A {==x==}[^rv-aaaa] {==b==}[^rv-new1].\n\n[^rv-aaaa]: @bob 2026-10-13: Hm.\n[^rv-new1]: @ulf 2026-10-14: Why?\n");
    check("comment on a file with no final newline", "Hello", comment("Hello", "Why?"), "{==Hello==}[^rv-new1]\n\n[^rv-new1]: @ulf 2026-10-14: Why?\n");
    check("comment after other footnotes gets a blank line", "Text[^1].\n\n[^1]: Plain footnote.\n", comment("Text", "Why?"), "{==Text==}[^rv-new1][^1].\n\n[^1]: Plain footnote.\n\n[^rv-new1]: @ulf 2026-10-14: Why?\n");
    check("comment inside a code block", "```swift\nlet x = 1\n```\nAfter.\n", comment("let x", "Why?"), "```swift\nlet x = 1\n```\n[^rv-new1]\nAfter.\n\n[^rv-new1]: @ulf 2026-10-14: Why?\n");
    check("comment inside a math block", "$$\nx^2\n$$\n", comment("x^2", "Why?"), "$$\nx^2\n$$\n[^rv-new1]\n\n[^rv-new1]: @ulf 2026-10-14: Why?\n");
    check("comment in a table cell", "| a | b |\n|---|---|\n| one | two |\n", comment("one", "Why?"), "| a | b |\n|---|---|\n| {==one==}[^rv-new1] | two |\n\n[^rv-new1]: @ulf 2026-10-14: Why?\n");
    check("multi-line comment body", "Text.\n", comment("Text", "Line one\n\nLine two  "), "{==Text==}[^rv-new1].\n\n[^rv-new1]: @ulf 2026-10-14: Line one\n    Line two\n");
    check("suggest a substitution", "It is rebuilt lazily.\n", suggest("lazily", "eagerly", "Clearer."), "It is rebuilt {~~lazily~>eagerly~~}[^rv-new1].\n\n[^rv-new1]: @ulf 2026-10-14 suggestion: Clearer.\n");
    check("suggest an insertion", "It is rebuilt.\n", insert("rebuilt", " eagerly"), "It is rebuilt{++ eagerly++}[^rv-new1].\n\n[^rv-new1]: @ulf 2026-10-14 suggestion: Clearer.\n");
    check("suggest a deletion with no body", "It is really rebuilt.\n", suggest("really ", "", ""), "It is {--really --}[^rv-new1]rebuilt.\n\n[^rv-new1]: @ulf 2026-10-14 suggestion:\n");
    check("reply appends an indented entry", "x[^rv-aaaa]\n\n[^rv-aaaa]: @bob 2026-10-13: Q?\n", reply("rv-aaaa", "A."), "x[^rv-aaaa]\n\n[^rv-aaaa]: @bob 2026-10-13: Q?\n    @ulf 2026-10-14: A.\n");
    check("reply lands after earlier replies", "x[^rv-aaaa] y[^rv-bbbb]\n\n[^rv-aaaa]: @bob 2026-10-13: Q?\n    @ann 2026-10-13: Hm.\n[^rv-bbbb]: @bob 2026-10-13: Other.\n", reply("rv-aaaa", "A.\nMore."), "x[^rv-aaaa] y[^rv-bbbb]\n\n[^rv-aaaa]: @bob 2026-10-13: Q?\n    @ann 2026-10-13: Hm.\n    @ulf 2026-10-14: A.\n    More.\n[^rv-bbbb]: @bob 2026-10-13: Other.\n");
    check("reply to a thread with no final newline", "x[^rv-aaaa]\n\n[^rv-aaaa]: @bob 2026-10-13: Q?", reply("rv-aaaa", "A."), "x[^rv-aaaa]\n\n[^rv-aaaa]: @bob 2026-10-13: Q?\n    @ulf 2026-10-14: A.");
    check("resolve a highlight", "The {==cache==}[^rv-aaaa] is stale.\n\n[^rv-aaaa]: @bob 2026-10-13: Why?\n    @ulf 2026-10-14: Because.\n", |o: &Ops| o.resolve("rv-aaaa"), "The cache is stale.\n");
    check("resolve a point comment", "Stale.[^rv-aaaa] Fresh.\n\n[^rv-aaaa]: @bob 2026-10-13: Source?\n", |o: &Ops| o.resolve("rv-aaaa"), "Stale. Fresh.\n");
    check("resolve a point comment after a code block", "```\ncode\n```\n[^rv-aaaa]\nAfter.\n\n[^rv-aaaa]: @bob 2026-10-13: Hm.\n", |o: &Ops| o.resolve("rv-aaaa"), "```\ncode\n```\nAfter.\n");
    check("resolve the middle thread", "a[^rv-aaaa] b[^rv-bbbb] c[^rv-cccc]\n\n[^rv-aaaa]: @x 2026-10-13: 1\n[^rv-bbbb]: @x 2026-10-13: 2\n    @y 2026-10-13: 2b\n[^rv-cccc]: @x 2026-10-13: 3\n", |o: &Ops| o.resolve("rv-bbbb"), "a[^rv-aaaa] b c[^rv-cccc]\n\n[^rv-aaaa]: @x 2026-10-13: 1\n[^rv-cccc]: @x 2026-10-13: 3\n");
    check("resolve the first thread", "a[^rv-aaaa] b[^rv-bbbb]\n\n[^rv-aaaa]: @x 2026-10-13: 1\n[^rv-bbbb]: @x 2026-10-13: 2\n", |o: &Ops| o.resolve("rv-aaaa"), "a b[^rv-bbbb]\n\n[^rv-bbbb]: @x 2026-10-13: 2\n");
    check("resolve highlight and point anchors", "{==a==}[^rv-aaaa] b[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-13: 1\n", |o: &Ops| o.resolve("rv-aaaa"), "a b\n");
    check("resolve does not settle a suggestion", "{++a++}[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: 1\n", |o: &Ops| o.resolve("rv-aaaa"), "{++a++}[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: 1\n");
    check("resolve an orphan thread", "Text.\n\n[^rv-aaaa]: @x 2026-10-13: lost\n", |o: &Ops| o.resolve("rv-aaaa"), "Text.\n");
    check("resolve a dangling anchor", "The {==cache==}[^rv-aaaa] is stale.\n", |o: &Ops| o.resolve("rv-aaaa"), "The cache is stale.\n");
    check("accept an insertion", "It is rebuilt{++ eagerly++}[^rv-aaaa].\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n", |o: &Ops| o.accept("rv-aaaa"), "It is rebuilt eagerly.\n");
    check("reject an insertion", "It is rebuilt{++ eagerly++}[^rv-aaaa].\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n", |o: &Ops| o.reject("rv-aaaa"), "It is rebuilt.\n");
    check("accept a deletion", "It is {--really --}[^rv-aaaa]rebuilt.\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n", |o: &Ops| o.accept("rv-aaaa"), "It is rebuilt.\n");
    check("reject a deletion", "It is {--really --}[^rv-aaaa]rebuilt.\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n", |o: &Ops| o.reject("rv-aaaa"), "It is really rebuilt.\n");
    check("accept a substitution", "It is {~~lazy~>eager~~}[^rv-aaaa].\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n", |o: &Ops| o.accept("rv-aaaa"), "It is eager.\n");
    check("reject a substitution", "It is {~~lazy~>eager~~}[^rv-aaaa].\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n", |o: &Ops| o.reject("rv-aaaa"), "It is lazy.\n");
    check("accept a comment resolves it", "{==a==}[^rv-aaaa] b[^rv-bbbb]\n\n[^rv-aaaa]: @x 2026-10-13: 1\n[^rv-bbbb]: @x 2026-10-13: 2\n", |o: &Ops| o.accept("rv-aaaa"), "a b[^rv-bbbb]\n\n[^rv-bbbb]: @x 2026-10-13: 2\n");
    check("reject a point comment resolves it", "b[^rv-bbbb]\n\n[^rv-bbbb]: @x 2026-10-13: 2\n", |o: &Ops| o.reject("rv-bbbb"), "b\n");
    check("accept a multi-anchor id", "The {==cache is invalidated on every save==}[^rv-k3f9] and the index is\n{~~rebuilt lazily~>rebuilt eagerly on open~~}[^rv-p2x7] from disk.\n{++Autosave writes are exempt.++}[^rv-p2x7] A point comment.[^rv-z9y8]\n\n[^rv-k3f9]: @ulf 2026-10-14: True for autosave too?\n    @claude 2026-10-14: No, see the added sentence.\n[^rv-p2x7]: @claude 2026-10-14 suggestion: Eager rebuild avoids the first-scroll stall.\n[^rv-z9y8]: @ulf 2026-10-14: Needs a source.\n", |o: &Ops| o.accept("rv-p2x7"), "The {==cache is invalidated on every save==}[^rv-k3f9] and the index is\nrebuilt eagerly on open from disk.\nAutosave writes are exempt. A point comment.[^rv-z9y8]\n\n[^rv-k3f9]: @ulf 2026-10-14: True for autosave too?\n    @claude 2026-10-14: No, see the added sentence.\n[^rv-z9y8]: @ulf 2026-10-14: Needs a source.\n");
    check("reject a multi-anchor id", "The {==cache is invalidated on every save==}[^rv-k3f9] and the index is\n{~~rebuilt lazily~>rebuilt eagerly on open~~}[^rv-p2x7] from disk.\n{++Autosave writes are exempt.++}[^rv-p2x7] A point comment.[^rv-z9y8]\n\n[^rv-k3f9]: @ulf 2026-10-14: True for autosave too?\n    @claude 2026-10-14: No, see the added sentence.\n[^rv-p2x7]: @claude 2026-10-14 suggestion: Eager rebuild avoids the first-scroll stall.\n[^rv-z9y8]: @ulf 2026-10-14: Needs a source.\n", |o: &Ops| o.reject("rv-p2x7"), "The {==cache is invalidated on every save==}[^rv-k3f9] and the index is\nrebuilt lazily from disk.\n A point comment.[^rv-z9y8]\n\n[^rv-k3f9]: @ulf 2026-10-14: True for autosave too?\n    @claude 2026-10-14: No, see the added sentence.\n[^rv-z9y8]: @ulf 2026-10-14: Needs a source.\n");
    check("accept a multi-block suggestion", "{--Old paragraph.--}[^rv-aaaa]\n\n{++New paragraph.++}[^rv-aaaa]\n\nKept.\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: Rewrite.\n", |o: &Ops| o.accept("rv-aaaa"), "\n\nNew paragraph.\n\nKept.\n");
    check("reject a multi-block suggestion", "{--Old paragraph.--}[^rv-aaaa]\n\n{++New paragraph.++}[^rv-aaaa]\n\nKept.\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: Rewrite.\n", |o: &Ops| o.reject("rv-aaaa"), "Old paragraph.\n\n\n\nKept.\n");
    check("accept a suggestion in a table cell", "| a |\n|---|\n| {~~one~>uno~~}[^rv-aaaa] |\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n", |o: &Ops| o.accept("rv-aaaa"), "| a |\n|---|\n| uno |\n");
    check("accept all keeps comments", "The {==cache is invalidated on every save==}[^rv-k3f9] and the index is\n{~~rebuilt lazily~>rebuilt eagerly on open~~}[^rv-p2x7] from disk.\n{++Autosave writes are exempt.++}[^rv-p2x7] A point comment.[^rv-z9y8]\n\n[^rv-k3f9]: @ulf 2026-10-14: True for autosave too?\n    @claude 2026-10-14: No, see the added sentence.\n[^rv-p2x7]: @claude 2026-10-14 suggestion: Eager rebuild avoids the first-scroll stall.\n[^rv-z9y8]: @ulf 2026-10-14: Needs a source.\n", |o: &Ops| o.accept_all(), "The {==cache is invalidated on every save==}[^rv-k3f9] and the index is\nrebuilt eagerly on open from disk.\nAutosave writes are exempt. A point comment.[^rv-z9y8]\n\n[^rv-k3f9]: @ulf 2026-10-14: True for autosave too?\n    @claude 2026-10-14: No, see the added sentence.\n[^rv-z9y8]: @ulf 2026-10-14: Needs a source.\n");
    check("reject all with several threads", "A {++b++}[^rv-aaaa] c {--d--}[^rv-bbbb] {~~e~>f~~}[^rv-cccc].\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: 1\n[^rv-bbbb]: @x 2026-10-13 suggestion: 2\n[^rv-cccc]: @x 2026-10-13 suggestion: 3\n", |o: &Ops| o.reject_all(), "A  c d e.\n");
    check("accept all, threads separated by blank lines", "A {++b++}[^rv-aaaa] c {--d--}[^rv-bbbb].\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: 1\n\n[^rv-bbbb]: @x 2026-10-13 suggestion: 2\n", |o: &Ops| o.accept_all(), "A b c .\n");
}

#[test]
fn refusals() {
    let text = "The {==cache==}[^rv-aaaa] is `stale code` here.\n\nSecond paragraph.\n\n[^rv-aaaa]: @x 2026-10-13: 1\n";
    let o = Ops::new(text);
    let comment = |r: std::ops::Range<usize>| o.add_comment(r, "b", &BY, Some("rv-new1"));
    let r = |n: &str| range(n, text);
    assert_eq!(comment(r("here.\n\nSecond")), vec![], "spans a blank line");
    assert_eq!(comment(r("che==}[^rv-aaaa] is")), vec![], "overlaps an anchor");
    assert_eq!(comment(r("[^rv-aaaa]")), vec![], "covers a ref");
    assert_eq!(comment(r("stale")), vec![], "inside a code span");
    assert_eq!(comment(r("@x")), vec![], "inside a thread definition");
    assert_eq!(comment(0..text.len() + 1), vec![], "out of bounds");
    let inside = r("{==ca").start + 2;
    assert_eq!(comment(inside..inside), vec![], "point inside an anchor");
    assert_eq!(o.add_suggestion(r("Second"), "x~~}y", "", &BY, Some("rv-new1")), vec![], "replacement breaks the markup");
    assert_eq!(o.add_suggestion(r("Second"), "a\n\nb", "", &BY, Some("rv-new1")), vec![], "replacement adds a block");
    assert_eq!(o.add_suggestion(5..5, "", "", &BY, Some("rv-new1")), vec![], "no change at all");
    assert!(!comment(r("Second")).is_empty(), "control: a valid range works");
    assert_eq!(o.add_comment(r("Second"), "b", &BY, Some("rv-aaaa")), vec![], "id already in use");
    assert_eq!(o.reply("rv-zzzz", "b", &BY), vec![], "no such thread");
    let code = "```\nlet x\n```\n";
    assert_eq!(Ops::new(code).add_suggestion(range("let", code), "var", "", &BY, Some("rv-new1")), vec![], "suggestion inside code");
}

#[test]
fn a_fresh_id_is_minted_when_none_is_given() {
    let text = "a[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-13: 1\n";
    let result = apply(&Ops::new(text).add_comment(0..1, "b", &BY, None), text).unwrap();
    let after = review::parse(&result);
    assert_eq!(after.problems, vec![]);
    assert_eq!(after.threads.len(), 2);
    assert_ne!(after.threads[1].id, "rv-aaaa");
}

#[test]
fn new_ids_have_the_shape_and_avoid_existing_ones() {
    let mut n = 0;
    let first = new_id_with(&HashSet::new(), |_| 0);
    assert_eq!(first, "rv-aaaa");
    let second = new_id_with(&HashSet::from([first.clone()]), |m| {
        n += 1;
        if n <= 4 { 0 } else { n % m }
    });
    assert_ne!(second, first);
    assert!(second.starts_with("rv-") && second.len() == 7);
    let system = tvmv::review_ops::new_id(&HashSet::new());
    assert!(system.starts_with("rv-") && system[3..].bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()), "{system}");
}

const CARDS_DOC: &str = "Intro paragraph.\n\nThe {==cache==}[^rv-a1b2] is {~~cold~>warm~~}[^rv-c3d4] today.\n\nAnother line with a point.[^rv-e5f6]\n\n[^rv-a1b2]: @ulf 2026-10-14: Why?\n    @claude 2026-10-14: Because.\n[^rv-c3d4]: @claude 2026-10-14 suggestion: Warmer.\n[^rv-e5f6]: @ulf 2026-10-14: Source?\n";

#[test]
fn one_card_per_thread_in_source_order() {
    use tvmv::review_ops::{CardKind, cards};
    let models = cards(&review::parse(CARDS_DOC), CARDS_DOC);
    assert_eq!(models.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["rv-a1b2", "rv-c3d4", "rv-e5f6"]);
    assert_eq!(models.iter().map(|m| m.kind).collect::<Vec<_>>(), [CardKind::Comment, CardKind::Suggestion, CardKind::Comment]);
    assert_eq!(models[0].entries.iter().map(|e| e.author.as_str()).collect::<Vec<_>>(), ["ulf", "claude"]);
    assert_eq!(models[1].change.as_deref(), Some("cold → warm"));
    assert_eq!(models[0].anchor, CARDS_DOC.find("cache").unwrap());
    let text = "A {==b==}[^rv-zzzz] c.\n\n[^rv-yyyy]: @ulf 2026-10-14: Lost.\n";
    let kinds: HashSet<CardKind> = cards(&review::parse(text), text).iter().map(|m| m.kind).collect();
    assert_eq!(kinds, HashSet::from([CardKind::DanglingAnchor, CardKind::OrphanThread]));
}

#[test]
fn cards_stack_without_overlapping_around_the_pinned_one() {
    use tvmv::review_ops::stack;
    assert_eq!(stack(&[(100, 50), (120, 50), (300, 50)], None, 8, 0), [100, 158, 300]);
    // Pinned second: it sits on its line, the first moves up.
    assert_eq!(stack(&[(100, 50), (120, 50), (300, 50)], Some(1), 8, 0), [62, 120, 300]);
    // No room above: everything moves down.
    assert_eq!(stack(&[(10, 50), (20, 50)], Some(1), 8, 0), [0, 58]);
}

#[test]
fn the_caret_follows_review_edits() {
    use tvmv::review_ops::caret_through;
    // A point comment at the end of "Hello": the caret goes after the ref,
    // not behind the hidden thread.
    let o = Ops::new("Hello");
    let edits = o.add_comment(5..5, "Hi", &BY, Some("rv-new1"));
    assert_eq!(caret_through(5, &edits), 5 + "[^rv-new1]".len());
    // Settling with the caret inside the change keeps it at the change.
    let text = "a {~~was~>is~~}[^rv-g7h8] omega\n\n[^rv-g7h8]: @ulf 2026-10-14 suggestion: c\n";
    let o = Ops::new(text);
    let edits = o.accept("rv-g7h8");
    assert_eq!(apply(&edits, text).unwrap(), "a is omega\n");
    assert_eq!(caret_through(text.find("was").unwrap() + 1, &edits), 2);
}

#[test]
fn the_author_is_git_s_first_name_lowercased() {
    use tvmv::review_ops::{author_handle, git_user_name, user_name_in_config};
    assert_eq!(author_handle(Some("Ulf Nielsen"), "un"), "ulf");
    assert_eq!(author_handle(Some("  "), "un"), "un");
    assert_eq!(author_handle(None, "Un"), "un");
    assert_eq!(user_name_in_config("[core]\n\tname = no\n[user]\n\tname = Ulf Nielsen\n").as_deref(), Some("Ulf Nielsen"));
    assert_eq!(user_name_in_config("[User]\n  Name = \"Ann B\" ; comment\n").as_deref(), Some("Ann B"));
    assert_eq!(user_name_in_config("[user]\n\temail = a@b\n"), None);
    let root = std::env::temp_dir().join(format!("tvmv-author-{}", std::process::id()));
    let (home, repo) = (root.join("home"), root.join("repo"));
    std::fs::create_dir_all(repo.join(".git")).unwrap();
    std::fs::create_dir_all(repo.join("docs")).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join(".gitconfig"), "[user]\n\tname = Global Person\n").unwrap();
    assert_eq!(git_user_name(Some(&repo.join("docs")), &home).as_deref(), Some("Global Person"));
    std::fs::write(repo.join(".git/config"), "[user]\n\tname = Repo Person\n").unwrap();
    assert_eq!(git_user_name(Some(&repo.join("docs")), &home).as_deref(), Some("Repo Person"));
    let _ = std::fs::remove_dir_all(&root);
}
