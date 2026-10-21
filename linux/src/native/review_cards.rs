//! The comment column right of the text: one card per review thread, and the
//! composer for a new comment or suggestion. A port of `ReviewCardView.swift`
//! and the side-column half of `DocumentTextView+Review.swift`.
//!
//! Cards sit in the text view's right gutter, a `gtk::Fixed` beside the
//! text, stacked beside their anchors' lines without overlapping
//! (`review_ops::stack`) and placed again as the text scrolls. Not overlays:
//! GTK's overlay container covers the whole text area and takes the clicks
//! meant for what lies under it (a table's cells). Only the
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

pub struct ReviewColumn {
    host: Weak<DocumentView>,
    pub cards: RefCell<Vec<Rc<Card>>>,
    pub composer: RefCell<Option<Rc<Composer>>>,
    focused: RefCell<Option<String>>,
    /// The right gutter the cards and the composer sit in.
    gutter: gtk4::Fixed,
    /// Where each card is in the gutter, so a layout moves only those that
    /// changed.
    placed: RefCell<Vec<(gtk4::Widget, i32, i32)>>,
    pending: Cell<bool>,
    me: Weak<ReviewColumn>,
}

impl ReviewColumn {
    pub fn new(host: &Rc<DocumentView>) -> Rc<ReviewColumn> {
        let gutter = gtk4::Fixed::new();
        gutter.set_size_request(COLUMN_WIDTH, -1);
        // Clicks in the column are the cards': passed on, the text view
        // would move its caret, out of the focused card's anchor, hiding the
        // button being pressed before the click completes.
        let clicks = gtk4::EventControllerLegacy::new();
        clicks.connect_event(|_, event| {
            use gtk4::gdk::EventType::*;
            match event.event_type() {
                ButtonPress | ButtonRelease | TouchBegin | TouchUpdate | TouchEnd | TouchCancel => glib::Propagation::Stop,
                _ => glib::Propagation::Proceed,
            }
        });
        gutter.add_controller(clicks);
        Rc::new_cyclic(|me| ReviewColumn {
            host: Rc::downgrade(host),
            cards: RefCell::default(),
            composer: RefCell::default(),
            focused: RefCell::default(),
            gutter,
            placed: RefCell::default(),
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
        self.sync_gutter(&host);
        self.queue_layout();
    }

    /// The gutter is there while there is something to show in it.
    fn sync_gutter(&self, host: &DocumentView) {
        let attached = self.gutter.parent().is_some();
        if self.shows() && !attached {
            host.view.set_gutter(gtk4::TextWindowType::Right, Some(&self.gutter));
        } else if !self.shows() && attached {
            host.view.set_gutter(gtk4::TextWindowType::Right, None::<&gtk4::Widget>);
        }
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
        self.sync_gutter(&host);
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
        self.sync_gutter(&host);
        host.review_column_changed();
        self.queue_layout();
        if had_focus {
            host.view.grab_focus();
        }
    }

    /// The text scrolled: the cards follow.
    pub fn scrolled(&self) {
        self.queue_layout();
    }

    fn attach(&self, _host: &DocumentView, content: &gtk4::Widget) {
        self.gutter.put(content, 0.0, 0.0);
    }

    fn detach(&self, content: &gtk4::Widget) {
        if content.parent().as_ref() == Some(self.gutter.upcast_ref()) {
            self.gutter.remove(content);
        }
        self.placed.borrow_mut().retain(|(w, _, _)| w != content);
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
        let (x, width) = (GAP, CARD_WIDTH);
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
        let mut placed = self.placed.borrow_mut();
        let mut bottom = 0;
        for ((_, widget, _), (&y, &(_, h))) in items.iter().zip(tops.iter().zip(measured.iter())) {
            bottom = bottom.max(y + h);
            // Buffer coordinates to the gutter's, which don't scroll.
            let (_, gy) = view.buffer_to_window_coords(gtk4::TextWindowType::Right, 0, y);
            match placed.iter_mut().find(|(w, _, _)| w == widget) {
                Some(entry) if entry.1 == x && entry.2 == gy => {}
                Some(entry) => {
                    self.gutter.move_(widget, x as f64, gy as f64);
                    entry.1 = x;
                    entry.2 = gy;
                }
                None => {
                    self.gutter.move_(widget, x as f64, gy as f64);
                    placed.push((widget.clone(), x, gy));
                }
            }
        }
        drop(placed);
        host.reserve_bottom(bottom);
    }
}
