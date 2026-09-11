//! Dumps WebKit's internal `webkit://gpu` report.
//!
//! This is WebKit's own account of its graphics configuration — which backing
//! store, which render node, which platform layer. It is the authoritative
//! answer to "is the dmabuf path in use", rather than inference from timings.
//!
//! Run: cargo run --release --example webkit_gpu_report

use gtk4::prelude::*;
use gtk4::glib;
use webkit6::prelude::*;

fn main() -> glib::ExitCode {
    tvmv::startup::apply_opt_out();

    let app = gtk4::Application::builder()
        .application_id("dk.dyregod.tvmv.gpureport")
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();

    app.connect_activate(|app| {
        // POLICY=always|never lets us see whether the setter actually takes.
        let settings = webkit6::Settings::new();
        match std::env::var("POLICY").as_deref() {
            Ok("always") => settings
                .set_hardware_acceleration_policy(webkit6::HardwareAccelerationPolicy::Always),
            Ok("never") => settings
                .set_hardware_acceleration_policy(webkit6::HardwareAccelerationPolicy::Never),
            _ => {}
        }
        let view = webkit6::WebView::builder().settings(&settings).build();
        eprintln!("requested={:?} settings_reports={:?}",
            std::env::var("POLICY").unwrap_or_else(|_| "(unset)".into()),
            settings.hardware_acceleration_policy());
        let window = gtk4::ApplicationWindow::builder()
            .application(app)
            .default_width(900)
            .default_height(700)
            .child(&view)
            .build();
        window.present();
        view.load_uri("webkit://gpu");

        let app = app.clone();
        let report_view = view.clone();
        glib::timeout_add_local_once(std::time::Duration::from_millis(3000), move || {
            report_view.evaluate_javascript(
                "document.body.innerText",
                None,
                None,
                gtk4::gio::Cancellable::NONE,
                move |result| {
                    match result {
                        Ok(value) => println!("{value}"),
                        Err(e) => eprintln!("failed to read webkit://gpu: {e}"),
                    }
                    app.quit();
                },
            );
        });
    });

    app.run_with_args::<&str>(&[])
}
