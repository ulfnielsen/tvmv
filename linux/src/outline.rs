//! The document outline sidebar.
//!
//! Fed by the `outline` message `boot.js` posts after every render; clicking a
//! row calls `window.tvmv.scrollToAnchor`. Headings are indented by level so the
//! document's shape is visible at a glance, matching the Mac sidebar.

use std::cell::RefCell;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{Label, ListBox, ListBoxRow, PolicyType, ScrolledWindow, SelectionMode};

use crate::preview::OutlineItem;

pub struct Outline {
    pub widget: ScrolledWindow,
    list: ListBox,
    /// Anchors by row index, so an activated row can be mapped back.
    anchors: Rc<RefCell<Vec<String>>>,
}

impl Outline {
    pub fn new(on_activate: impl Fn(&str) + 'static) -> Self {
        let list = ListBox::new();
        list.set_selection_mode(SelectionMode::Single);
        list.add_css_class("navigation-sidebar");

        let anchors: Rc<RefCell<Vec<String>>> = Rc::new(RefCell::new(Vec::new()));
        let activate_anchors = Rc::clone(&anchors);
        list.connect_row_activated(move |_, row| {
            let index = row.index();
            if index < 0 {
                return;
            }
            if let Some(anchor) = activate_anchors.borrow().get(index as usize) {
                on_activate(anchor);
            }
        });

        let widget = ScrolledWindow::builder()
            .hscrollbar_policy(PolicyType::Never)
            .vscrollbar_policy(PolicyType::Automatic)
            .child(&list)
            .width_request(220)
            .build();
        widget.add_css_class("tvmv-sidebar");

        Self { widget, list, anchors }
    }

    /// Replace the outline. Called on every render, so it must be cheap and must
    /// not flicker the selection when the content is unchanged.
    pub fn set_items(&self, items: &[OutlineItem]) {
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }

        let mut anchors = Vec::with_capacity(items.len());
        for item in items {
            let label = Label::new(Some(&item.title));
            label.set_xalign(0.0);
            label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
            label.set_tooltip_text(Some(&item.title));
            // h1 sits flush; every level below steps in. Levels are clamped so a
            // document that jumps straight to h6 does not indent off-screen.
            let depth = item.level.clamp(1, 6) - 1;
            label.set_margin_start(8 + (depth as i32) * 12);
            label.set_margin_end(8);
            label.set_margin_top(4);
            label.set_margin_bottom(4);
            if item.level <= 1 {
                label.add_css_class("heading");
            } else if item.level >= 4 {
                label.add_css_class("dim-label");
            }

            let row = ListBoxRow::new();
            row.set_child(Some(&label));
            self.list.append(&row);
            anchors.push(item.anchor.clone());
        }
        *self.anchors.borrow_mut() = anchors;
    }

    pub fn is_empty(&self) -> bool {
        self.anchors.borrow().is_empty()
    }
}
