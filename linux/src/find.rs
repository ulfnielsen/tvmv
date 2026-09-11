//! Find-in-page.
//!
//! The searching itself lives in `boot.js` (`find` / `findNext` / `clearFind`),
//! shared with the Mac and iOS apps; this is only the bar around it. Both JS
//! entry points return `{count, index}`, which drives the match counter.

use std::cell::Cell;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{Box as GtkBox, Button, Label, Orientation, SearchBar, SearchEntry};

/// What the find bar asks the page to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FindAction {
    Search,
    Next,
    Previous,
    Clear,
}

pub struct Find {
    pub widget: SearchBar,
    entry: SearchEntry,
    counter: Label,
    /// Suppresses the change handler while we set the entry programmatically.
    updating: Rc<Cell<bool>>,
}

impl Find {
    /// `on_action` receives the action and the current query.
    pub fn new(on_action: impl Fn(FindAction, &str) + 'static) -> Self {
        let entry = SearchEntry::new();
        entry.set_placeholder_text(Some("Find in document"));
        entry.set_hexpand(true);

        let counter = Label::new(None);
        counter.add_css_class("dim-label");
        // Reserve room so the bar does not jitter as the count changes.
        counter.set_width_chars(9);
        counter.set_xalign(1.0);

        // Icons by freedesktop name only — never shipped. They resolve against
        // the installed theme, so this follows Adwaita, Breeze or Papirus
        // automatically. Shipping our own is what makes an app look imported.
        let previous = Button::from_icon_name("go-up-symbolic");
        previous.set_tooltip_text(Some("Previous match (Shift+Enter)"));
        previous.add_css_class("flat");
        let next = Button::from_icon_name("go-down-symbolic");
        next.set_tooltip_text(Some("Next match (Enter)"));
        next.add_css_class("flat");
        let close = Button::from_icon_name("window-close-symbolic");
        close.set_tooltip_text(Some("Close (Escape)"));
        close.add_css_class("flat");

        let row = GtkBox::new(Orientation::Horizontal, 6);
        row.set_margin_start(6);
        row.set_margin_end(6);
        row.append(&entry);
        row.append(&counter);
        row.append(&previous);
        row.append(&next);
        row.append(&close);

        let widget = SearchBar::builder().show_close_button(false).build();
        widget.set_child(Some(&row));
        widget.connect_entry(&entry);
        widget.add_css_class("tvmv-findbar");

        let on_action = Rc::new(on_action);
        let updating = Rc::new(Cell::new(false));

        {
            let on_action = Rc::clone(&on_action);
            let updating = Rc::clone(&updating);
            entry.connect_search_changed(move |entry| {
                if updating.get() {
                    return;
                }
                on_action(FindAction::Search, &entry.text());
            });
        }
        {
            let on_action = Rc::clone(&on_action);
            entry.connect_activate(move |entry| on_action(FindAction::Next, &entry.text()));
        }
        {
            let on_action = Rc::clone(&on_action);
            let entry_for_next = entry.clone();
            next.connect_clicked(move |_| on_action(FindAction::Next, &entry_for_next.text()));
        }
        {
            let on_action = Rc::clone(&on_action);
            let entry_for_prev = entry.clone();
            previous.connect_clicked(move |_| {
                on_action(FindAction::Previous, &entry_for_prev.text())
            });
        }
        {
            let on_action = Rc::clone(&on_action);
            let bar = widget.clone();
            close.connect_clicked(move |_| {
                bar.set_search_mode(false);
                on_action(FindAction::Clear, "");
            });
        }

        Self { widget, entry, counter, updating }
    }

    /// Show the bar and focus the entry, preserving any previous query.
    pub fn open(&self) {
        self.widget.set_search_mode(true);
        self.entry.grab_focus();
        self.entry.select_region(0, -1);
    }

    pub fn close(&self) {
        self.widget.set_search_mode(false);
    }

    pub fn is_open(&self) -> bool {
        self.widget.is_search_mode()
    }

    pub fn query(&self) -> String {
        self.entry.text().to_string()
    }

    /// Update the match counter. `index` is 1-based; 0 means no matches.
    pub fn set_matches(&self, count: i64, index: i64) {
        self.updating.set(true);
        if self.entry.text().is_empty() {
            self.counter.set_text("");
            self.entry.remove_css_class("error");
        } else if count == 0 {
            self.counter.set_text("No results");
            self.entry.add_css_class("error");
        } else {
            self.counter.set_text(&format!("{index} of {count}"));
            self.entry.remove_css_class("error");
        }
        self.updating.set(false);
    }
}
