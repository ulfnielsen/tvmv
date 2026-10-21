//! Table edits as source edits, from the Swift `TableSourceTests`.

use tvmv::layout::{Table, parse};
use tvmv::table_source::{Command, Edit, cell_edit, cell_text, reformat};

const TEXT: &str = "Intro.\n\n| Name | Score |\n|:-----|------:|\n| Ada  | 10 |\n| Bob | 7 |\n\nAfter.\n";

fn table(text: &str) -> Table {
    parse(text).tables[0].clone()
}

fn apply(text: &str, edit: &Edit) -> String {
    format!("{}{}{}", &text[..edit.range.start], edit.insert, &text[edit.range.end..])
}

#[test]
fn a_cell_edit_patches_that_cells_source_only() {
    let edit = cell_edit(&table(TEXT), 1, 0, 3..3, "m");
    assert_eq!(apply(TEXT, &edit), TEXT.replace("| Ada  |", "| Adam  |"));
}

#[test]
fn a_typed_pipe_is_escaped() {
    let edit = cell_edit(&table(TEXT), 2, 1, 1..1, "|");
    assert_eq!(apply(TEXT, &edit), TEXT.replace("| 7 |", "| 7\\| |"));
}

#[test]
fn cell_text_is_its_source_escapes_included() {
    let escaped = "| A |\n|---|\n| x \\| y |\n";
    assert_eq!(cell_text(&table(escaped), 1, 0, escaped), "x \\| y");
}

#[test]
fn structure_changes_rewrite_the_table_neatly() {
    let add_row = reformat(&table(TEXT), TEXT, |cells, _| cells.insert(2, vec![String::new(), String::new()]));
    assert_eq!(
        apply(TEXT, &add_row),
        "Intro.\n\n| Name | Score |\n| :--- | ----: |\n| Ada  |    10 |\n|      |       |\n| Bob  |     7 |\n\nAfter.\n"
    );
    let add_column = reformat(&table(TEXT), TEXT, |cells, alignments| {
        for (i, row) in cells.iter_mut().enumerate() {
            row.push(if i == 0 { "Note".into() } else { String::new() });
        }
        alignments.push(tvmv::layout::Alignment::Center);
    });
    assert_eq!(
        apply(TEXT, &add_column),
        "Intro.\n\n| Name | Score | Note |\n| :--- | ----: | :--: |\n| Ada  |    10 |      |\n| Bob  |     7 |      |\n\nAfter.\n"
    );
}

#[test]
fn reformat_pads_by_characters() {
    let wide = "| A | B |\n|---|---|\n| 😀 | é |\n";
    let edit = reformat(&table(wide), wide, |_, _| {});
    assert_eq!(apply(wide, &edit), "| A   | B   |\n| --- | --- |\n| 😀   | é   |\n");
}

#[test]
fn commands_act_on_their_cell_and_keep_the_header() {
    let t = table(TEXT);
    let below = Command::InsertRowBelow.edit(&t, TEXT, 1, 0).unwrap();
    assert!(apply(TEXT, &below).contains("| Ada  |    10 |\n|      |       |\n| Bob  |     7 |"));
    let above_header = Command::InsertRowAbove.edit(&t, TEXT, 0, 0).unwrap();
    assert!(apply(TEXT, &above_header).contains("| :--- | ----: |\n|      |       |\n| Ada"), "never above the header");
    assert_eq!(Command::DeleteRow.edit(&t, TEXT, 0, 0), None, "the header row stays");
    let deleted = apply(TEXT, &Command::DeleteRow.edit(&t, TEXT, 2, 0).unwrap());
    assert!(!deleted.contains("Bob"));
    let right = apply(TEXT, &Command::InsertColumnRight.edit(&t, TEXT, 1, 0).unwrap());
    assert!(right.contains("| Name |     | Score |"), "{right}");
    let center = apply(TEXT, &Command::AlignCenter.edit(&t, TEXT, 1, 0).unwrap());
    assert!(center.contains("| :--: | ----: |"), "{center}");
    let single = "| A |\n|---|\n| x |\n";
    assert_eq!(Command::DeleteColumn.edit(&table(single), single, 1, 0), None, "the last column stays");
    assert_eq!(Command::DeleteRow.edit(&table(single), single, 1, 0), None, "the last body row stays");
}
