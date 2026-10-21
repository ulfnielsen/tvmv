//! The comment column right of the text: one card per review thread, and the
//! composer for a new comment or suggestion. A port of `ReviewCardView.swift`
//! and the side-column half of `DocumentTextView+Review.swift`.
//!
//! Cards are overlays of the text view, in buffer coordinates, stacked beside
//! their anchors' lines without overlapping (`review_ops::stack`). Only the
//! focused card (the caret is in its anchor, or it was clicked) shows its
//! buttons and reply field, so the others stay compact by their lines.

use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

use gtk4::prelude::*;
use gtk4::{glib, pango};

use crate::review_ops::{CardKind, CardModel};

use super::document_view::DocumentView;

/// The column: a gap, the cards, a margin.
pub const GAP: i32 = 24;
pub const CARD_WIDTH: i32 = 280;
pub const RIGHT_MARGIN: i32 = 20;
pub const COLUMN_WIDTH: i32 = GAP + CARD_WIDTH + RIGHT_MARGIN;
const STACK_GAP: i32 = 8;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    Accept,
    Reject,
    Resolve,
    Reply(String),
    DeleteThread,
    RemoveMarkup,
}

/// One thread's card.
pub struct Card {
    pub model: RefCell<CardModel>,
    pub widget: gtk4::Box,
    /// The buttons and the reply field: shown on the focused card only.
    actions: gtk4::Box,
    pub reply: Option<gtk4::Entry>,
    focused: Cell<bool>,
}

impl Card {
    fn new(model: CardModel, column: &Rc<ReviewColumn>) -> Rc<Card> {
        let widget = gtk4::Box::new(gtk4::Orientation::Vertical, 6);
        widget.add_css_class("tvmv-card");
        let small = |text: &str, class: &str| {
            let label = gtk4::Label::new(Some(text));
            label.set_xalign(0.0);
            label.set_wrap(true);
            label.set_wrap_mode(pango::WrapMode::WordChar);
            label.add_css_class(class);
            label.set_selectable(false);
            label
        };
        let (heading, problem) = match model.kind {
            CardKind::Comment => ("COMMENT", false),
            CardKind::Suggestion => ("SUGGESTION", false),
            CardKind::OrphanThread => ("THREAD WITHOUT ANCHOR", true),
            CardKind::DanglingAnchor => ("MARKUP WITHOUT THREAD", true),
        };
        let head = small(heading, "tvmv-card-heading");
        if problem {
            head.add_css_class("problem");
        }
        widget.append(&head);
        if let Some(change) = &model.change {
            widget.append(&small(change, "tvmv-card-change"));
        }
        for entry in &model.entries {
            let label = gtk4::Label::new(None);
            label.set_markup(&format!(
                "<b>@{}</b>  <span alpha=\"60%\">{}</span>\n{}",
                glib::markup_escape_text(&entry.author),
                glib::markup_escape_text(&entry.date),
                glib::markup_escape_text(&entry.body)
            ));
            label.set_xalign(0.0);
            label.set_wrap(true);
            label.set_wrap_mode(pango::WrapMode::WordChar);
            label.set_selectable(true);
            label.add_css_class("tvmv-card-entry");
            widget.append(&label);
        }
        let actions = gtk4::Box::new(gtk4::Orientation::Vertical, 6);
        let buttons = gtk4::Box::new(gtk4::Orientation::Horizontal, 6);
        let id = model.id.clone();
        let add = |title: &str, action: Action| {
            let button = gtk4::Button::with_label(title);
            button.add_css_class("tvmv-card-button");
            let column = Rc::downgrade(column);
            let id = id.clone();
            button.connect_clicked(move |_| {
                if let Some(column) = column.upgrade() {
                    column.act(&id, action.clone());
                }
            });
            buttons.append(&button);
        };
        match model.kind {
            CardKind::Suggestion => {
                add("Accept", Action::Accept);
                add("Reject", Action::Reject);
            }
            CardKind::Comment => add("Resolve", Action::Resolve),
            CardKind::OrphanThread => add("Delete Thread", Action::DeleteThread),
            CardKind::DanglingAnchor => add("Remove Markup", Action::RemoveMarkup),
        }
        actions.append(&buttons);
        let reply = matches!(model.kind, CardKind::Comment | CardKind::Suggestion).then(|| {
            let entry = gtk4::Entry::new();
            entry.set_placeholder_text(Some("Reply"));
            let column = Rc::downgrade(column);
            let id = id.clone();
            entry.connect_activate(move |entry| {
                let body = entry.text().trim().to_string();
                if body.is_empty() {
                    return;
                }
                entry.set_text("");
                if let Some(column) = column.upgrade() {
                    column.act(&id, Action::Reply(body));
                }
            });
            actions.append(&entry);
            entry
        });
        actions.set_visible(false);
        widget.append(&actions);
        // A click in the card's own space focuses it.
        let click = gtk4::GestureClick::new();
        {
            let column = Rc::downgrade(column);
            let id = id.clone();
            click.connect_released(move |_, _, _, _| {
                if let Some(column) = column.upgrade() {
                    column.focus(Some(&id), true);
                }
            });
        }
        widget.add_controller(click);
        Rc::new(Card { model: RefCell::new(model), widget, actions, reply, focused: Cell::new(false) })
    }

    pub fn id(&self) -> String {
        self.model.borrow().id.clone()
    }

    pub fn is_focused(&self) -> bool {
        self.focused.get()
    }

    fn set_focused(&self, on: bool) {
        if self.focused.replace(on) == on {
            return;
        }
        self.actions.set_visible(on);
        if on {
            self.widget.add_css_class("focused");
        } else {
            self.widget.remove_css_class("focused");
        }
    }

    /// The button labelled `title` (tests).
    pub fn button(&self, title: &str) -> Option<gtk4::Button> {
        let mut stack = vec![self.widget.clone().upcast::<gtk4::Widget>()];
        while let Some(w) = stack.pop() {
            if let Ok(b) = w.clone().downcast::<gtk4::Button>()
                && b.label().as_deref() == Some(title)
            {
                return Some(b);
            }
            let mut c = w.first_child();
            while let Some(child) = c {
                c = child.next_sibling();
                stack.push(child);
            }
        }
        None
    }
}

/// A new comment or suggestion, written in a card in the column.
pub struct Composer {
    pub widget: gtk4::Box,
    pub body: gtk4::Entry,
    pub replacement: Option<gtk4::Entry>,
    pub message: gtk4::Label,
    /// Where the selection starts: the composer lines up with it.
    pub anchor: usize,
    submitted: Cell<bool>,
}

/// What the composer asks the document to do: `Ok(())` once added, or why it
/// couldn't be.
pub type Submit = Box<dyn Fn(&str, Option<&str>) -> Result<(), String>>;

impl Composer {
    fn new(suggestion: Option<&str>, anchor: usize, column: &Rc<ReviewColumn>, submit: Submit) -> Rc<Composer> {
        let widget = gtk4::Box::new(gtk4::Orientation::Vertical, 8);
        widget.add_css_class("tvmv-card");
        widget.add_css_class("focused");
        let title = gtk4::Label::new(Some(if suggestion.is_some() { "SUGGEST EDIT" } else { "NEW COMMENT" }));
        title.set_xalign(0.0);
        title.add_css_class("tvmv-card-heading");
        title.add_css_class("problem");
        widget.append(&title);
        let replacement = suggestion.map(|s| {
            let entry = gtk4::Entry::new();
            entry.set_text(s);
            entry.set_placeholder_text(Some("Replace with (empty deletes)"));
            widget.append(&entry);
            entry
        });
        let body = gtk4::Entry::new();
        body.set_placeholder_text(Some(if suggestion.is_some() { "Note (optional)" } else { "Comment" }));
        widget.append(&body);
        let message = gtk4::Label::new(None);
        message.set_xalign(0.0);
        message.set_wrap(true);
        message.add_css_class("error");
        message.set_visible(false);
        widget.append(&message);
        let buttons = gtk4::Box::new(gtk4::Orientation::Horizontal, 6);
        let cancel = gtk4::Button::with_label("Cancel");
        let add = gtk4::Button::with_label("Add");
        add.add_css_class("suggested-action");
        buttons.append(&cancel);
        buttons.append(&add);
        widget.append(&buttons);
        let composer = Rc::new(Composer { widget, body, replacement, message, anchor, submitted: Cell::new(false) });
        let submit = Rc::new(submit);
        let fire = {
            let composer = Rc::downgrade(&composer);
            let column = Rc::downgrade(column);
            move || {
                let (Some(composer), Some(column)) = (composer.upgrade(), column.upgrade()) else { return };
                composer.submit(&submit, &column);
            }
        };
        {
            let fire = fire.clone();
            add.connect_clicked(move |_| fire());
        }
        for entry in std::iter::once(&composer.body).chain(composer.replacement.as_ref()) {
            let fire = fire.clone();
            entry.connect_activate(move |_| fire());
        }
        {
            let column = Rc::downgrade(column);
            cancel.connect_clicked(move |_| {
                if let Some(column) = column.upgrade() {
                    column.close_composer();
                }
            });
        }
        let keys = gtk4::EventControllerKey::new();
        {
            let column = Rc::downgrade(column);
            keys.connect_key_pressed(move |_, key, _, _| {
                if key == gtk4::gdk::Key::Escape
                    && let Some(column) = column.upgrade()
                {
                    column.close_composer();
                    return glib::Propagation::Stop;
                }
                glib::Propagation::Proceed
            });
        }
        composer.widget.add_controller(keys);
        composer
    }

    /// Add the comment, once.
    pub fn submit(&self, submit: &Submit, column: &ReviewColumn) {
        if self.submitted.get() {
            return;
        }
        let body = self.body.text().trim().to_string();
        let replacement = self.replacement.as_ref().map(|e| e.text().to_string());
        if replacement.is_none() && body.is_empty() {
            return;
        }
        match submit(&body, replacement.as_deref()) {
            Ok(()) => {
                self.submitted.set(true);
                column.close_composer();
            }
            Err(problem) => {
                self.message.set_text(&problem);
                self.message.set_visible(true);
                column.queue_layout();
            }
        }
    }
}

/// An overlay of the text view holding a card or the composer, or nothing.
struct Slot {
    frame: gtk4::Box,
    content: Option<gtk4::Widget>,
    at: Option<(i32, i32)>,
}

pub struct ReviewColumn {
    host: Weak<DocumentView>,
    pub cards: RefCell<Vec<Rc<Card>>>,
    pub composer: RefCell<Option<Rc<Composer>>>,
    focused: RefCell<Option<String>>,
    /// The overlays cards and the composer sit in, each with what it holds
    /// and where it is. GTK 4.14's `TextView::remove` does not remove an
    /// overlay (it warns "not a child"), so an overlay is never removed: a
    /// card that goes empties its slot, and the next card reuses it.
    slots: RefCell<Vec<Slot>>,
    pending: Cell<bool>,
    me: Weak<ReviewColumn>,
}

impl ReviewColumn {
    pub fn new(host: &Rc<DocumentView>) -> Rc<ReviewColumn> {
        Rc::new_cyclic(|me| ReviewColumn {
            host: Rc::downgrade(host),
            cards: RefCell::default(),
            composer: RefCell::default(),
            focused: RefCell::default(),
            slots: RefCell::default(),
            pending: Cell::new(false),
            me: me.clone(),
        })
    }

    /// Whether the column takes room beside the text.
    pub fn shows(&self) -> bool {
        !self.cards.borrow().is_empty() || self.composer.borrow().is_some()
    }

    pub fn focused_id(&self) -> Option<String> {
        self.focused.borrow().clone()
    }

    /// Show `models`. Cards whose content is unchanged stay as they are: an
    /// edit moves anchors on every keystroke, and a rebuild would lose a reply
    /// being written.
    pub fn update(&self, models: Vec<CardModel>) {
        let Some(host) = self.host.upgrade() else { return };
        let me = self.me.upgrade().expect("a live column");
        let mut old: Vec<Rc<Card>> = self.cards.borrow_mut().drain(..).collect();
        let mut cards = Vec::with_capacity(models.len());
        for model in models {
            if let Some(i) = old.iter().position(|c| c.model.borrow().shows_same(&model)) {
                let card = old.remove(i);
                *card.model.borrow_mut() = model;
                cards.push(card);
            } else {
                let card = Card::new(model, &me);
                self.attach(&host, card.widget.upcast_ref());
                cards.push(card);
            }
        }
        for card in old {
            self.detach(card.widget.upcast_ref());
        }
        let focused = self.focused.borrow().clone();
        for card in &cards {
            card.set_focused(focused.as_deref() == Some(card.id().as_str()));
        }
        *self.cards.borrow_mut() = cards;
        self.queue_layout();
    }

    /// Focus the card for `id` (none for `None`); `clicked` when from a click.
    pub fn focus(&self, id: Option<&str>, clicked: bool) {
        let changed = self.focused.borrow().as_deref() != id;
        *self.focused.borrow_mut() = id.map(str::to_string);
        for card in self.cards.borrow().iter() {
            card.set_focused(Some(card.id().as_str()) == id);
        }
        if changed || clicked {
            self.queue_layout();
        }
    }

    fn act(&self, id: &str, action: Action) {
        if let Some(host) = self.host.upgrade() {
            host.card_action(id, action);
        }
    }

    /// Open the composer at source offset `anchor`.
    pub fn open_composer(&self, suggestion: Option<&str>, anchor: usize, submit: Submit) {
        let Some(host) = self.host.upgrade() else { return };
        self.close_composer();
        let me = self.me.upgrade().expect("a live column");
        let composer = Composer::new(suggestion, anchor, &me, submit);
        self.attach(&host, composer.widget.upcast_ref());
        let focus = composer.replacement.clone().unwrap_or_else(|| composer.body.clone());
        *self.composer.borrow_mut() = Some(composer);
        host.review_column_changed();
        self.queue_layout();
        glib::idle_add_local_once(move || {
            focus.grab_focus();
        });
    }

    pub fn close_composer(&self) {
        let Some(composer) = self.composer.borrow_mut().take() else { return };
        let Some(host) = self.host.upgrade() else { return };
        let had_focus = composer.widget.focus_child().is_some();
        self.detach(composer.widget.upcast_ref());
        host.review_column_changed();
        self.queue_layout();
        if had_focus {
            host.view.grab_focus();
        }
    }

    /// The text scrolled. GTK 4.14 moves overlays only when their container
    /// is allocated, which scrolling doesn't do; and allocating the view
    /// alone passes the container the same rectangle, so it is skipped.
    pub fn scrolled(&self) {
        // The view passes its scroll offset to the container as it is
        // allocated; the container then places the overlays with it.
        if let Some(host) = self.host.upgrade() {
            host.view.queue_allocate();
        }
        if let Some(parent) = self.slots.borrow().first().and_then(|s| s.frame.parent()) {
            parent.queue_allocate();
        }
    }

    /// Put `content` in a free slot (a new overlay if none is free).
    fn attach(&self, host: &DocumentView, content: &gtk4::Widget) {
        let mut slots = self.slots.borrow_mut();
        let i = match slots.iter().position(|s| s.content.is_none()) {
            Some(i) => i,
            None => {
                let frame = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
                host.view.add_overlay(&frame, 0, 0);
                slots.push(Slot { frame, content: None, at: None });
                slots.len() - 1
            }
        };
        let slot = &mut slots[i];
        slot.frame.append(content);
        slot.frame.set_visible(true);
        slot.content = Some(content.clone());
        slot.at = None;
    }

    /// Take `content` out of its slot, which hides until reused.
    fn detach(&self, content: &gtk4::Widget) {
        for slot in self.slots.borrow_mut().iter_mut() {
            if slot.content.as_ref() == Some(content) {
                slot.frame.remove(content);
                slot.frame.set_visible(false);
                slot.content = None;
            }
        }
    }

    pub fn queue_layout(&self) {
        if self.pending.replace(true) {
            return;
        }
        let me = self.me.clone();
        glib::idle_add_local_once(move || {
            if let Some(column) = me.upgrade() {
                column.pending.set(false);
                column.layout();
            }
        });
    }

    /// Place the cards and the composer beside their lines.
    pub fn layout(&self) {
        let Some(host) = self.host.upgrade() else { return };
        let view = &host.view;
        let column_end = view.width() - view.right_margin();
        let x = column_end + GAP;
        let width = (CARD_WIDTH + 20).min(view.width() - x - RIGHT_MARGIN).max(200);
        let mut items: Vec<(usize, gtk4::Widget, bool)> =
            self.cards.borrow().iter().map(|c| (c.model.borrow().anchor, c.widget.clone().upcast(), c.is_focused())).collect();
        if let Some(c) = self.composer.borrow().as_ref() {
            items.push((c.anchor, c.widget.clone().upcast(), true));
        }
        items.sort_by_key(|i| i.0);
        let measured: Vec<(i32, i32)> = items
            .iter()
            .map(|(anchor, widget, _)| {
                widget.set_size_request(width, -1);
                let (_, natural, _, _) = widget.measure(gtk4::Orientation::Vertical, width);
                (host.line_top(*anchor), natural)
            })
            .collect();
        let composer = self.composer.borrow().as_ref().map(|c| c.widget.clone().upcast::<gtk4::Widget>());
        let pinned = items
            .iter()
            .position(|i| Some(&i.1) == composer.as_ref())
            .or_else(|| items.iter().position(|i| i.2));
        let tops = crate::review_ops::stack(&measured, pinned, STACK_GAP, view.top_margin());
        let mut slots = self.slots.borrow_mut();
        let mut bottom = 0;
        for ((_, widget, _), (&y, &(_, h))) in items.iter().zip(tops.iter().zip(measured.iter())) {
            bottom = bottom.max(y + h);
            if let Some(slot) = slots.iter_mut().find(|s| s.content.as_ref() == Some(widget))
                && slot.at != Some((x, y))
            {
                view.move_overlay(&slot.frame, x, y);
                slot.at = Some((x, y));
            }
        }
        drop(slots);
        host.reserve_bottom(bottom);
    }
}
