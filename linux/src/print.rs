//! Printing and Save-as-PDF.
//!
//! Both go through `WebKitPrintOperation`, which prints the web view exactly as
//! rendered — so the `@media print` rules in the shared `app.css` apply, and the
//! output matches the Mac app's rather than being a second implementation.
//!
//! The print dialog is GTK's, which on a portal-enabled desktop is the portal's:
//! KDE users get the Plasma dialog. It already offers "Print to File", so
//! Save-as-PDF is strictly a convenience — but a common enough one for a
//! document reader to be worth its own shortcut.

use gtk4::prelude::*;
use gtk4::{ApplicationWindow, PrintSettings, glib};
use webkit6::WebView;
use webkit6::prelude::*;

use crate::settings::Settings;

/// GTK print-settings keys. Spelled out rather than guessed at: the GTK
/// constants are not exposed by the Rust bindings.
const OUTPUT_URI: &str = "output-uri";
const OUTPUT_FILE_FORMAT: &str = "output-file-format";
/// The virtual printer GTK uses for file output.
const PRINT_TO_FILE: &str = "Print to File";

/// Show the print dialog for `view`; `done` once printing has finished or
/// was cancelled.
pub fn print(view: &WebView, parent: &ApplicationWindow, done: impl Fn() + 'static) {
    let operation = webkit6::PrintOperation::new(view);
    report_failures(&operation);
    let done = std::rc::Rc::new(done);
    {
        let done = std::rc::Rc::clone(&done);
        operation.connect_finished(move |_| done());
    }
    // `run_dialog` handles the whole interaction, including Print to File.
    if operation.run_dialog(Some(parent)) == webkit6::PrintOperationResponse::Cancel {
        done();
    }
}

/// Ask for a destination, then write a PDF without showing the print dialog;
/// `done` once it is written or the dialog was cancelled.
pub fn save_as_pdf(view: &WebView, parent: &ApplicationWindow, suggested_name: &str, done: impl Fn() + 'static) {
    let dialog = gtk4::FileDialog::builder()
        .title("Save as PDF")
        .initial_name(suggested_name)
        .modal(true)
        .build();

    let view = view.clone();
    let parent = parent.clone();
    dialog.save(Some(&parent), gtk4::gio::Cancellable::NONE, move |result| {
        let Ok(file) = result else {
            done();
            return;
        };
        let uri: String = file.uri().into();

        let settings = PrintSettings::new();
        // Both are needed: the printer selects file output, the format decides
        // PDF over PostScript.
        settings.set_printer(PRINT_TO_FILE);
        settings.set(OUTPUT_URI, Some(&uri));
        settings.set(OUTPUT_FILE_FORMAT, Some("pdf"));

        let operation = webkit6::PrintOperation::new(&view);
        operation.set_print_settings(&settings);
        report_failures(&operation);
        operation.connect_finished(move |_| done());
        // No dialog: the destination is already chosen.
        operation.print();
    });
}

/// Write a PDF with no dialog at all, calling `on_done` when the operation
/// settles. Used by `tvmv --pdf`, and the reason the print path can be tested
/// without a desktop session in the loop.
pub fn export_pdf(
    view: &WebView,
    destination: &std::path::Path,
    on_done: impl Fn(bool) + 'static,
) {
    let uri = gtk4::gio::File::for_path(destination).uri();

    let settings = PrintSettings::new();
    settings.set_printer(PRINT_TO_FILE);
    settings.set(OUTPUT_URI, Some(&uri));
    settings.set(OUTPUT_FILE_FORMAT, Some("pdf"));

    let operation = webkit6::PrintOperation::new(view);
    operation.set_print_settings(&settings);

    let done = std::rc::Rc::new(on_done);
    {
        let done = std::rc::Rc::clone(&done);
        operation.connect_failed(move |_, error| {
            eprintln!("tvmv: printing failed: {error}");
            done(false);
        });
    }
    {
        let done = std::rc::Rc::clone(&done);
        // `finished` fires after `failed` too, so the failure handler above is
        // what distinguishes them; this one must not report success blindly.
        let failed = std::cell::Cell::new(false);
        operation.connect_failed(move |_, _| failed.set(true));
        operation.connect_finished(move |_| done(true));
    }
    // The operation must outlive this call; WebKit owns it once started.
    operation.print();
    std::mem::forget(operation);
}

/// Where `print_markdown` sends the document.
pub enum Output {
    /// The print dialog.
    Dialog(ApplicationWindow),
    /// Ask for a file name (the suggestion given), then write a PDF there.
    SaveAs(ApplicationWindow, String),
    /// Write a PDF to this path, then report success.
    File(std::path::PathBuf, Box<dyn Fn(bool)>),
}

/// Print `markdown` through the web pipeline, from a web view nobody sees.
/// The native window has no web view of its own; this one renders the text
/// as it stands, unsaved edits included, with the reader's typography and
/// the custom stylesheet, so print matches the web reader's.
pub fn print_markdown(markdown: &str, document_dir: Option<std::path::PathBuf>, settings: &Settings, output: Output) {
    use std::cell::RefCell;
    use std::rc::Rc;

    use crate::preview::{Preview, PreviewMessage};

    let web = crate::resources::web_source();
    // The preview reports to a closure that needs the preview: through a
    // slot, emptied when printing has started, which ends the cycle.
    let slot: Rc<RefCell<Option<Rc<Preview>>>> = Rc::default();
    let output = Rc::new(RefCell::new(Some(output)));
    let preview = Rc::new(Preview::new(&web, {
        let slot = Rc::clone(&slot);
        move |message| {
            let PreviewMessage::RenderComplete = message else { return };
            let Some(output) = output.borrow_mut().take() else { return };
            let Some(preview) = slot.borrow_mut().take() else { return };
            // renderComplete means the DOM is final, including the lazy KaTeX
            // and Mermaid passes; give layout a moment to settle after them.
            glib::timeout_add_local_once(std::time::Duration::from_millis(300), move || {
                let view = preview.web_view.clone();
                // The hidden window holds the view; it goes when printing ends.
                let finish = {
                    let view = view.clone();
                    move || {
                        if let Some(host) = view.root().and_downcast::<gtk4::Window>() {
                            host.destroy();
                        }
                    }
                };
                match output {
                    Output::Dialog(parent) => print(&view, &parent, finish),
                    Output::SaveAs(parent, name) => save_as_pdf(&view, &parent, &name, finish),
                    Output::File(path, done) => export_pdf(&view, &path, move |ok| {
                        finish();
                        done(ok);
                    }),
                }
                drop(preview);
            });
        }
    }));
    *slot.borrow_mut() = Some(Rc::clone(&preview));
    // WebKit prints only a view that belongs to a realized window. This one
    // is never shown, and is destroyed when printing ends.
    let host = gtk4::Window::new();
    host.set_default_size(800, 1000);
    host.set_child(Some(&preview.web_view));
    WidgetExt::realize(&host);
    preview.set_document_directory(document_dir);
    let style = settings.style_json(false);
    let user_css = crate::window::read_user_css(settings);
    let markdown = markdown.to_string();
    let weak = Rc::downgrade(&preview);
    preview.web_view.connect_load_changed(move |_, event| {
        if event != webkit6::LoadEvent::Finished {
            return;
        }
        let Some(preview) = weak.upgrade() else { return };
        preview.apply_style(&style);
        preview.apply_user_css(&user_css);
        let html = crate::render::render_html(&markdown, true);
        preview.render(&html, &format!("{}://doc/", crate::assets::SCHEME));
    });
    preview.load_template();
}

/// A failed print is silent otherwise, which reads as the command doing nothing.
fn report_failures(operation: &webkit6::PrintOperation) {
    operation.connect_failed(|_, error| eprintln!("tvmv: printing failed: {error}"));
}

/// `document.md` -> `document.pdf`.
pub fn pdf_name_for(path: &std::path::Path) -> String {
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned());
    match stem {
        Some(stem) if !stem.is_empty() => format!("{stem}.pdf"),
        _ => "document.pdf".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::pdf_name_for;
    use std::path::Path;

    #[test]
    fn derives_the_pdf_name_from_the_document() {
        assert_eq!(pdf_name_for(Path::new("/tmp/README.md")), "README.pdf");
        assert_eq!(pdf_name_for(Path::new("notes.markdown")), "notes.pdf");
    }

    /// A name with dots keeps everything but the final extension, so
    /// `2026-08-28.notes.md` does not become `2026-08-28.pdf`.
    #[test]
    fn keeps_interior_dots() {
        assert_eq!(pdf_name_for(Path::new("2026-08-28.notes.md")), "2026-08-28.notes.pdf");
    }

    #[test]
    fn falls_back_when_there_is_no_usable_stem() {
        assert_eq!(pdf_name_for(Path::new("/")), "document.pdf");
        assert_eq!(pdf_name_for(Path::new("")), "document.pdf");
    }
}
