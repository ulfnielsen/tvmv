//! Reports what the display advertises for dmabuf sharing.
//!
//! WebKitGTK decides between its dmabuf and shared-memory backing stores partly
//! on what GTK says the display can import. If this prints zero formats, that
//! alone explains a silent fallback to SHM — and points the fix at GTK/the
//! compositor rather than at WebKit.
//!
//! Run: cargo run --release --example dmabuf_probe

use gtk4::prelude::*;
use gtk4::{Application, glib};

/// Render a DRM fourcc as its four ASCII characters.
fn fourcc(code: u32) -> String {
    code.to_le_bytes().iter().map(|b| *b as char).collect()
}

fn main() -> glib::ExitCode {
    let app = Application::builder()
        .application_id("dk.dyregod.tvmv.dmabufprobe")
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();

    app.connect_activate(|app| {
        // A realized surface is needed before the display has negotiated
        // anything with the compositor.
        let window = gtk4::ApplicationWindow::builder()
            .application(app)
            .default_width(200)
            .default_height(100)
            .build();
        window.present();

        let app = app.clone();
        glib::timeout_add_local_once(std::time::Duration::from_millis(700), move || {
            let Some(display) = gtk4::gdk::Display::default() else {
                println!("no display");
                app.quit();
                return;
            };

            println!("display backend: {}", display.type_().name());

            let formats = display.dmabuf_formats();
            let n = formats.n_formats();
            println!("gdk_display_get_dmabuf_formats(): {n} formats");

            if n == 0 {
                println!("  => the display advertises NO dmabuf formats.");
            } else {
                // Group by fourcc; modifiers are the long tail.
                let mut seen: Vec<(String, usize, bool)> = Vec::new();
                for i in 0..n {
                    let (code, modifier) = formats.format(i);
                    let name = fourcc(code);
                    let linear = modifier == 0;
                    match seen.iter_mut().find(|(f, _, _)| *f == name) {
                        Some(entry) => {
                            entry.1 += 1;
                            entry.2 |= linear;
                        }
                        None => seen.push((name, 1, linear)),
                    }
                }
                println!("  {} distinct fourccs:", seen.len());
                for (name, count, has_linear) in seen.iter().take(12) {
                    println!("    {name}  {count} modifier(s){}", if *has_linear { ", incl. LINEAR" } else { "" });
                }

                // The formats WebKit actually wants for its backing store.
                for want in ["AR24", "XR24", "AB24", "XB24"] {
                    let code = u32::from_le_bytes([
                        want.as_bytes()[0], want.as_bytes()[1],
                        want.as_bytes()[2], want.as_bytes()[3],
                    ]);
                    let any = (0..n).any(|i| formats.format(i).0 == code);
                    let linear = formats.contains(code, 0);
                    println!("  {want}: present={any} linear_modifier={linear}");
                }
            }
            app.quit();
        });
    });

    app.run_with_args::<&str>(&[])
}
