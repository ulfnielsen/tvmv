//! The native view's undo stack, in source offsets.
//!
//! GTK's own undo is off: the buffer is not the file (soft breaks show as
//! spaces, and those swaps must never be undone), so every edit is recorded
//! here as the source change it made. Typing and runs of deletes coalesce
//! into one step, as in a word processor.

use std::ops::Range;
use std::time::{Duration, Instant};

/// One replacement: `range` (in the text before it) held `removed` and now
/// holds `inserted`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub range: Range<usize>,
    pub removed: String,
    pub inserted: String,
}

impl Change {
    /// The change that undoes this one, against the text after it.
    pub fn inverse(&self) -> Change {
        Change {
            range: self.range.start..self.range.start + self.inserted.len(),
            removed: self.inserted.clone(),
            inserted: self.removed.clone(),
        }
    }
}

/// Changes undone and redone together, and where the caret goes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Step {
    pub changes: Vec<Change>,
    pub caret_before: usize,
    pub caret_after: usize,
}

#[derive(Default)]
pub struct UndoStack {
    undo: Vec<Step>,
    redo: Vec<Step>,
    /// Open group depth, and the changes recorded meanwhile.
    group: usize,
    pending: Option<Step>,
    /// When the last step was recorded, and whether it may absorb the next
    /// keystroke.
    last: Option<(Instant, bool)>,
}

/// Typing pauses longer than this start a new step.
const COALESCE: Duration = Duration::from_secs(2);

fn is_typing(change: &Change) -> bool {
    change.removed.is_empty() && !change.inserted.is_empty() && !change.inserted.contains('\n')
}

fn is_delete(change: &Change) -> bool {
    change.inserted.is_empty() && !change.removed.is_empty() && !change.removed.contains('\n')
}

/// A typed character or a deleted one: what coalesces into a running step.
fn is_keystroke(change: &Change) -> bool {
    (is_typing(change) && change.inserted.chars().count() == 1)
        || (is_delete(change) && change.removed.chars().count() == 1)
}

impl UndoStack {
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    pub fn clear(&mut self) {
        *self = UndoStack::default();
    }

    /// Changes until the matching `end_group` form one step. A group of one
    /// keystroke still coalesces with the step before it (GTK wraps every
    /// keystroke in a user action).
    pub fn begin_group(&mut self) {
        self.group += 1;
    }

    pub fn end_group(&mut self) {
        self.group = self.group.saturating_sub(1);
        if self.group == 0 {
            if let Some(step) = self.pending.take() {
                self.commit(step);
            }
        }
    }

    /// Record a change made with the caret at `caret_before`, leaving it at
    /// `caret_after`.
    pub fn record(&mut self, change: Change, caret_before: usize, caret_after: usize) {
        self.redo.clear();
        let step = match self.pending.take() {
            Some(mut step) => {
                step.changes.push(change);
                step.caret_after = caret_after;
                step
            }
            None => Step { changes: vec![change], caret_before, caret_after },
        };
        if self.group > 0 {
            self.pending = Some(step);
        } else {
            self.commit(step);
        }
    }

    fn commit(&mut self, step: Step) {
        let now = Instant::now();
        let keystroke = matches!(step.changes.as_slice(), [c] if is_keystroke(c));
        let recent = self.last.is_some_and(|(at, mergeable)| mergeable && now.duration_since(at) < COALESCE);
        if keystroke && recent && self.merge(&step.changes[0], step.caret_after) {
            self.last = Some((now, true));
            return;
        }
        self.undo.push(step);
        self.last = Some((now, keystroke));
    }

    /// Fold a keystroke into the last step when it continues it.
    fn merge(&mut self, change: &Change, caret_after: usize) -> bool {
        let Some(step) = self.undo.last_mut() else { return false };
        let [last] = step.changes.as_mut_slice() else { return false };
        if is_typing(last) && is_typing(change) && change.range.start == last.range.start + last.inserted.len() {
            // A word boundary ends a typing step.
            if last.inserted.ends_with(' ') && !change.inserted.starts_with(' ') && !last.inserted.trim().is_empty() {
                return false;
            }
            last.inserted.push_str(&change.inserted);
        } else if is_delete(last) && is_delete(change) && change.range.end == last.range.start {
            // Backspace: the run grows to the left.
            last.removed.insert_str(0, &change.removed);
            last.range.start = change.range.start;
        } else if is_delete(last) && is_delete(change) && change.range.start == last.range.start {
            // Forward delete: the run grows to the right.
            last.removed.push_str(&change.removed);
            last.range.end += change.removed.len();
        } else {
            return false;
        }
        step.caret_after = caret_after;
        true
    }

    /// The step to undo: apply its changes' inverses, last first.
    pub fn undo(&mut self) -> Option<Step> {
        let step = self.undo.pop()?;
        self.redo.push(step.clone());
        self.last = None;
        Some(step)
    }

    /// The step to redo: apply its changes, first first.
    pub fn redo(&mut self) -> Option<Step> {
        let step = self.redo.pop()?;
        self.undo.push(step.clone());
        self.last = None;
        Some(step)
    }
}

/// Apply `change` to `text` (for tests and for checking a replay).
pub fn apply(text: &mut String, change: &Change) {
    text.replace_range(change.range.clone(), &change.inserted);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn typed(at: usize, s: &str) -> Change {
        Change { range: at..at, removed: String::new(), inserted: s.into() }
    }

    fn deleted(text: &str, range: Range<usize>) -> Change {
        Change { removed: text[range.clone()].into(), range, inserted: String::new() }
    }

    fn undo_all(stack: &mut UndoStack, text: &mut String) {
        while let Some(step) = stack.undo() {
            for change in step.changes.iter().rev() {
                apply(text, &change.inverse());
            }
        }
    }

    #[test]
    fn typing_coalesces_by_word() {
        let mut stack = UndoStack::default();
        let mut text = String::new();
        for (i, c) in "ab cd".chars().enumerate() {
            let change = typed(i, &c.to_string());
            apply(&mut text, &change);
            stack.record(change, i, i + 1);
        }
        assert_eq!(stack.undo.len(), 2, "\"ab \" then \"cd\"");
        let step = stack.undo().unwrap();
        apply(&mut text, &step.changes[0].inverse());
        assert_eq!(text, "ab ");
        assert_eq!(step.caret_before, 3);
    }

    #[test]
    fn backspace_and_forward_delete_runs_coalesce() {
        let mut stack = UndoStack::default();
        let mut text = String::from("hello world");
        for at in [10, 9, 8] {
            let change = deleted(&text, at..at + 1);
            apply(&mut text, &change);
            stack.record(change, at + 1, at);
        }
        for _ in 0..2 {
            let change = deleted(&text, 0..1);
            apply(&mut text, &change);
            stack.record(change, 0, 0);
        }
        assert_eq!(text, "llo wo");
        assert_eq!(stack.undo.len(), 2);
        undo_all(&mut stack, &mut text);
        assert_eq!(text, "hello world");
    }

    #[test]
    fn groups_and_newlines_are_steps_of_their_own() {
        let mut stack = UndoStack::default();
        let mut text = String::from("x");
        stack.begin_group();
        for change in [typed(1, "*"), typed(0, "*")] {
            apply(&mut text, &change);
            stack.record(change, 0, 0);
        }
        stack.end_group();
        let change = typed(3, "\n");
        apply(&mut text, &change);
        stack.record(change, 3, 4);
        let change = typed(4, "y");
        apply(&mut text, &change);
        stack.record(change, 4, 5);
        assert_eq!(text, "*x*\ny");
        assert_eq!(stack.undo.len(), 3);
        undo_all(&mut stack, &mut text);
        assert_eq!(text, "x");
    }

    #[test]
    fn a_keystroke_in_its_own_group_still_coalesces() {
        let mut stack = UndoStack::default();
        for (i, c) in ["a", "b"].iter().enumerate() {
            stack.begin_group();
            stack.record(typed(i, c), i, i + 1);
            stack.end_group();
        }
        assert_eq!(stack.undo.len(), 1);
        // Typing over a selection is two changes: a step of its own.
        stack.begin_group();
        stack.record(Change { range: 0..2, removed: "ab".into(), inserted: String::new() }, 2, 0);
        stack.record(typed(0, "c"), 0, 1);
        stack.end_group();
        assert_eq!(stack.undo.len(), 2);
    }

    #[test]
    fn redo_replays_and_a_new_edit_clears_it() {
        let mut stack = UndoStack::default();
        let mut text = String::from("a");
        let change = typed(1, "b");
        apply(&mut text, &change);
        stack.record(change, 1, 2);
        let step = stack.undo().unwrap();
        apply(&mut text, &step.changes[0].inverse());
        assert!(stack.can_redo());
        let step = stack.redo().unwrap();
        apply(&mut text, &step.changes[0]);
        assert_eq!(text, "ab");
        stack.undo();
        stack.record(typed(1, "c"), 1, 2);
        assert!(!stack.can_redo());
    }
}
