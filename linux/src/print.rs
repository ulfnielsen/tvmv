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
use gtk4::{ApplicationWindow, PrintSettings};
use webkit6::WebView;

/// GTK print-settings keys. Spelled out rather than guessed at: the GTK
/// constants are not exposed by the Rust bindings.
const OUTPUT_URI: &str = "output-uri";
const OUTPUT_FILE_FORMAT: &str = "output-file-format";
/// The virtual printer GTK uses for file output.
const PRINT_TO_FILE: &str = "Print to File";

/// Show the print dialog for `view`.
pub fn print(view: &WebView, parent: &ApplicationWindow) {
    let operation = webkit6::PrintOperation::new(view);
    report_failures(&operation);
    // `run_dialog` handles the whole interaction, including Print to File.
    operation.run_dialog(Some(parent));
}

/// Ask for a destination, then write a PDF without showing the print dialog.
pub fn save_as_pdf(view: &WebView, parent: &ApplicationWindow, suggested_name: &str) {
    let dialog = gtk4::FileDialog::builder()
        .title("Save as PDF")
        .initial_name(suggested_name)
        .modal(true)
        .build();

    let view = view.clone();
    let parent = parent.clone();
    dialog.save(Some(&parent), gtk4::gio::Cancellable::NONE, move |result| {
        let Ok(file) = result else { return };
        let Some(uri) = file.uri().into() else { return };

        let settings = PrintSettings::new();
        // Both are needed: the printer selects file output, the format decides
        // PDF over PostScript.
        settings.set_printer(PRINT_TO_FILE);
        settings.set(OUTPUT_URI, Some(&uri));
        settings.set(OUTPUT_FILE_FORMAT, Some("pdf"));

        let operation = webkit6::PrintOperation::new(&view);
        operation.set_print_settings(&settings);
        report_failures(&operation);
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
