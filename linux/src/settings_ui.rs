//! The settings window.
//!
//! A plain `GtkWindow` with `GtkListBox` rows — no libadwaita, so it inherits
//! the user's GTK theme rather than overriding it (see the spec's "Looking
//! native on every shell"). Every change applies live to all open windows and
//! persists immediately; there is no OK/Cancel, matching the Mac app.

use std::cell::RefCell;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{
    Box as GtkBox, Button, DropDown, Label, ListBox, Orientation, PolicyType, ScrolledWindow,
    SelectionMode, SpinButton, StringList, Switch, Window,
};

use crate::settings::{Settings, Theme};

/// Applied on every change: persist, then push to every open window.
type OnChange = Rc<dyn Fn(&Settings)>;

pub fn present(parent: &impl IsA<Window>, settings: Rc<RefCell<Settings>>, on_change: OnChange) {
    let window = Window::builder()
        .title("Settings")
        .transient_for(parent)
        .modal(false)
        .default_width(460)
        .default_height(560)
        .build();

    let list = ListBox::new();
    list.set_selection_mode(SelectionMode::None);
    list.add_css_class("boxed-list");
    list.set_margin_top(12);
    list.set_margin_bottom(12);
    list.set_margin_start(12);
    list.set_margin_end(12);

    let commit = {
        let settings = Rc::clone(&settings);
        let on_change = Rc::clone(&on_change);
        move || {
            let snapshot = settings.borrow().clone();
            if let Err(e) = snapshot.save() {
                eprintln!("tvmv: could not save settings: {e}");
            }
            on_change(&snapshot);
        }
    };
    let commit: Rc<dyn Fn()> = Rc::new(commit);

    // --- appearance -------------------------------------------------------

    let themes = StringList::new(&["Follow system", "Light", "Dark"]);
    let theme = DropDown::builder().model(&themes).build();
    theme.set_selected(match settings.borrow().theme {
        Theme::Auto => 0,
        Theme::Light => 1,
        Theme::Dark => 2,
    });
    {
        let settings = Rc::clone(&settings);
        let commit = Rc::clone(&commit);
        theme.connect_selected_notify(move |drop| {
            settings.borrow_mut().theme = match drop.selected() {
                1 => Theme::Light,
                2 => Theme::Dark,
                _ => Theme::Auto,
            };
            commit();
        });
    }
    list.append(&row("Theme", "Light or dark, or follow the desktop", &theme));

    // --- fonts ------------------------------------------------------------
    //
    // Families come from fontconfig via Pango, so a user cannot type a family
    // that does not resolve. The value is ONE family name, never a chain:
    // boot.js emits `JSON.stringify(cfg.monoFont) + ", monospace"`, so a
    // comma-separated value would be quoted whole and match nothing.

    let families = font_families(&list, false);
    let mono_families = font_families(&list, true);

    let (body, body_values) = family_dropdown(&families, &settings.borrow().body_font);
    {
        let settings = Rc::clone(&settings);
        let commit = Rc::clone(&commit);
        body.connect_selected_notify(move |drop| {
            // Indexes the value list, not the family list: a "(not installed)"
            // placeholder shifts the model by one.
            if let Some(name) = body_values.get(drop.selected() as usize) {
                settings.borrow_mut().body_font = name.clone();
                commit();
            }
        });
    }
    list.append(&row("Body font", "Used for prose", &body));

    let (mono, mono_values) = family_dropdown(&mono_families, &settings.borrow().mono_font);
    {
        let settings = Rc::clone(&settings);
        let commit = Rc::clone(&commit);
        mono.connect_selected_notify(move |drop| {
            if let Some(name) = mono_values.get(drop.selected() as usize) {
                settings.borrow_mut().mono_font = name.clone();
                commit();
            }
        });
    }
    list.append(&row("Code font", "Used for code and the editor", &mono));

    // --- measurements -----------------------------------------------------

    let size = SpinButton::with_range(8.0, 48.0, 1.0);
    size.set_value(settings.borrow().base_size);
    {
        let settings = Rc::clone(&settings);
        let commit = Rc::clone(&commit);
        size.connect_value_changed(move |spin| {
            settings.borrow_mut().base_size = spin.value();
            commit();
        });
    }
    list.append(&row("Text size", "Base font size in points", &size));

    let measure = SpinButton::with_range(40.0, 140.0, 1.0);
    measure.set_value(settings.borrow().measure);
    {
        let settings = Rc::clone(&settings);
        let commit = Rc::clone(&commit);
        measure.connect_value_changed(move |spin| {
            settings.borrow_mut().measure = spin.value();
            commit();
        });
    }
    list.append(&row("Line width", "Characters per line, for comfortable reading", &measure));

    let full_width = Switch::new();
    full_width.set_active(settings.borrow().full_width);
    full_width.set_valign(gtk4::Align::Center);
    {
        let settings = Rc::clone(&settings);
        let commit = Rc::clone(&commit);
        full_width.connect_active_notify(move |sw| {
            settings.borrow_mut().full_width = sw.is_active();
            commit();
        });
    }
    list.append(&row("Full width", "Ignore the line width and fill the window", &full_width));

    let outline = Switch::new();
    outline.set_active(settings.borrow().show_outline);
    outline.set_valign(gtk4::Align::Center);
    {
        let settings = Rc::clone(&settings);
        let commit = Rc::clone(&commit);
        outline.connect_active_notify(move |sw| {
            settings.borrow_mut().show_outline = sw.is_active();
            commit();
        });
    }
    list.append(&row("Show outline", "Sidebar of headings in new windows", &outline));

    // --- custom CSS -------------------------------------------------------

    let css_label = Label::new(None);
    css_label.set_ellipsize(gtk4::pango::EllipsizeMode::Start);
    css_label.add_css_class("dim-label");
    css_label.set_hexpand(true);
    css_label.set_xalign(1.0);
    set_css_label(&css_label, &settings.borrow().custom_css_path);

    let choose = Button::with_label("Choose…");
    let clear = Button::from_icon_name("edit-clear-symbolic");
    clear.set_tooltip_text(Some("Use the built-in theme"));
    clear.add_css_class("flat");

    {
        let settings = Rc::clone(&settings);
        let commit = Rc::clone(&commit);
        let css_label = css_label.clone();
        let window = window.clone();
        choose.connect_clicked(move |_| {
            let filter = gtk4::FileFilter::new();
            filter.set_name(Some("Stylesheets"));
            filter.add_pattern("*.css");
            let filters = gtk4::gio::ListStore::new::<gtk4::FileFilter>();
            filters.append(&filter);

            // GtkFileDialog routes through the XDG portal, so KDE users get the
            // Plasma chooser rather than a GTK one that looks imported.
            let dialog = gtk4::FileDialog::builder()
                .title("Choose a stylesheet")
                .filters(&filters)
                .default_filter(&filter)
                .modal(true)
                .build();

            let settings = Rc::clone(&settings);
            let commit = Rc::clone(&commit);
            let css_label = css_label.clone();
            dialog.open(Some(&window), gtk4::gio::Cancellable::NONE, move |result| {
                let Ok(file) = result else { return };
                let Some(path) = file.path() else {
                    eprintln!("tvmv: that stylesheet is not a local file");
                    return;
                };
                let path = path.to_string_lossy().into_owned();
                set_css_label(&css_label, &path);
                settings.borrow_mut().custom_css_path = path;
                commit();
            });
        });
    }
    {
        let settings = Rc::clone(&settings);
        let commit = Rc::clone(&commit);
        let css_label = css_label.clone();
        clear.connect_clicked(move |_| {
            settings.borrow_mut().custom_css_path.clear();
            set_css_label(&css_label, "");
            commit();
        });
    }

    let css_controls = GtkBox::new(Orientation::Horizontal, 6);
    css_controls.append(&css_label);
    css_controls.append(&choose);
    css_controls.append(&clear);
    list.append(&row("Custom CSS", "Overrides the built-in theme", &css_controls));

    let scroller = ScrolledWindow::builder()
        .hscrollbar_policy(PolicyType::Never)
        .vscrollbar_policy(PolicyType::Automatic)
        .child(&list)
        .build();
    window.set_child(Some(&scroller));

    // Escape closes, as everything applies live and there is nothing to cancel.
    let keys = gtk4::EventControllerKey::new();
    let closable = window.clone();
    keys.connect_key_pressed(move |_, key, _, _| {
        if key == gtk4::gdk::Key::Escape {
            closable.close();
            return gtk4::glib::Propagation::Stop;
        }
        gtk4::glib::Propagation::Proceed
    });
    window.add_controller(keys);

    window.present();
}

/// One settings row: title and subtitle on the left, control on the right.
fn row(title: &str, subtitle: &str, control: &impl IsA<gtk4::Widget>) -> gtk4::ListBoxRow {
    let text = GtkBox::new(Orientation::Vertical, 2);
    let title_label = Label::new(Some(title));
    title_label.set_xalign(0.0);
    let subtitle_label = Label::new(Some(subtitle));
    subtitle_label.set_xalign(0.0);
    subtitle_label.add_css_class("dim-label");
    subtitle_label.add_css_class("caption");
    text.append(&title_label);
    text.append(&subtitle_label);
    text.set_hexpand(true);

    let content = GtkBox::new(Orientation::Horizontal, 12);
    content.set_margin_top(8);
    content.set_margin_bottom(8);
    content.set_margin_start(12);
    content.set_margin_end(12);
    content.append(&text);
    content.append(control);

    let row = gtk4::ListBoxRow::new();
    row.set_activatable(false);
    row.set_child(Some(&content));
    row
}

fn set_css_label(label: &Label, path: &str) {
    if path.is_empty() {
        label.set_text("Built-in theme");
    } else {
        label.set_text(path);
    }
    label.set_tooltip_text(if path.is_empty() { None } else { Some(path) });
}

/// Installed font families, from fontconfig via Pango.
fn font_families(widget: &impl IsA<gtk4::Widget>, monospace_only: bool) -> Vec<String> {
    let mut names: Vec<String> = widget
        .as_ref()
        .pango_context()
        .list_families()
        .iter()
        .filter(|family| !monospace_only || family.is_monospace())
        .map(|family| family.name().to_string())
        .collect();
    names.sort_by_key(|n| n.to_lowercase());
    names.dedup();
    names
}

/// A dropdown over `families`, selecting `current`.
///
/// The configured family may not be installed — `Source Serif 4` is the default
/// and ships with the Mac app, not with Linux — so it is prepended rather than
/// silently replaced by whatever sorts first, which would rewrite the user's
/// setting the moment they opened this window.
fn family_dropdown(families: &[String], current: &str) -> (DropDown, Vec<String>) {
    let mut labels = families.to_vec();
    // Values parallel to the model, so a selection maps to the family to store.
    let mut values = families.to_vec();

    let selected = match families.iter().position(|n| n == current) {
        Some(index) => index,
        None if !current.is_empty() => {
            labels.insert(0, format!("{current} (not installed)"));
            // The placeholder's value is the family itself, so selecting it is a
            // no-op rather than silently rewriting the setting.
            values.insert(0, current.to_string());
            0
        }
        None => 0,
    };

    let refs: Vec<&str> = labels.iter().map(String::as_str).collect();
    let model = StringList::new(&refs);
    let drop = DropDown::builder().model(&model).build();
    drop.set_selected(selected as u32);
    (drop, values)
}
