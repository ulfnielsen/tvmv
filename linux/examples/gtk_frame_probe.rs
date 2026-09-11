//! A GTK4-only frame-rate probe. No WebKit, no TVMV.
//!
//! Measures the frame clock's `after-paint` intervals, exactly as
//! `tvmv --frame-bench` does, so the two are directly comparable.
//!
//! Two modes, because the distinction matters:
//!
//! - `PROBE_MODE=gpu` (default): moves a CSS-coloured box inside a `GtkFixed`.
//!   GSK emits a colour node the GPU composites, so per-frame CPU cost is
//!   near-zero regardless of window size. **This is the honest control** for
//!   "can GTK present this surface at the refresh rate?"
//! - `PROBE_MODE=cairo`: the original, drawing with cairo in a draw func. That
//!   is CPU rasterisation by design, so it goes slow at large sizes on any
//!   hardware — it cannot tell you anything about GTK or the driver. Kept only
//!   because the X11-session finding was measured with it at a small size,
//!   where its own cost is negligible.
//!
//! Run: PROBE_SIZE=1200 cargo run --release --example gtk_frame_probe

use std::cell::RefCell;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::{Application, ApplicationWindow, DrawingArea, glib};

fn main() -> glib::ExitCode {
    let app = Application::builder()
        .application_id("dk.dyregod.tvmv.frameprobe")
        .flags(gtk4::gio::ApplicationFlags::NON_UNIQUE)
        .build();

    app.connect_activate(|app| {
        let size: i32 = std::env::var("PROBE_SIZE").ok().and_then(|s| s.parse().ok()).unwrap_or(900);

        let cairo_mode = std::env::var("PROBE_MODE").as_deref() == Ok("cairo");
        let offset = Rc::new(RefCell::new(0.0f64));

        let window = ApplicationWindow::builder()
            .application(app)
            .title("frame probe")
            .default_width(size)
            .default_height(size)
            .build();

        if cairo_mode {
            let area = DrawingArea::new();
            let draw_offset = Rc::clone(&offset);
            area.set_draw_func(move |_, cr, w, h| {
                let x = *draw_offset.borrow() % (w as f64).max(1.0);
                cr.set_source_rgb(0.98, 0.96, 0.91);
                let _ = cr.paint();
                cr.set_source_rgb(0.8, 0.35, 0.2);
                cr.rectangle(x, 0.0, 80.0, h as f64);
                let _ = cr.fill();
            });
            window.set_child(Some(&area));
            let tick_area = area.clone();
            area.add_tick_callback(move |_, _| {
                *offset.borrow_mut() += 6.0;
                tick_area.queue_draw();
                glib::ControlFlow::Continue
            });
        } else {
            // GPU path: GSK composites a colour node; moving it costs no
            // per-pixel CPU work, so the frame rate reflects presentation only.
            let provider = gtk4::CssProvider::new();
            provider.load_from_string(
                "window { background: #FBF8F2; } .probe { background: #B83F12; }",
            );
            if let Some(display) = gtk4::gdk::Display::default() {
                gtk4::style_context_add_provider_for_display(
                    &display,
                    &provider,
                    gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
                );
            }

            let block = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
            block.add_css_class("probe");
            block.set_size_request(80, size);

            let fixed = gtk4::Fixed::new();
            fixed.put(&block, 0.0, 0.0);
            window.set_child(Some(&fixed));

            let move_fixed = fixed.clone();
            let move_block = block.clone();
            let span = (size - 80).max(1) as f64;
            window.add_tick_callback(move |_, _| {
                let mut o = offset.borrow_mut();
                *o = (*o + 6.0) % span;
                move_fixed.move_(&move_block, *o, 0.0);
                glib::ControlFlow::Continue
            });
        }

        window.present();

        let Some(clock) = WidgetExt::frame_clock(&window) else { return };
        if let Some(t) = clock.current_timings() {
            eprintln!("  refresh_interval={:.2}ms", t.refresh_interval() as f64 / 1000.0);
        }

        let stamps: Rc<RefCell<Vec<i64>>> = Rc::new(RefCell::new(Vec::new()));
        let recorder = Rc::clone(&stamps);
        clock.connect_after_paint(move |c| recorder.borrow_mut().push(c.frame_time()));

        let app = app.clone();
        glib::timeout_add_local_once(std::time::Duration::from_millis(5000), move || {
            let s = stamps.borrow();
            let mut gaps: Vec<f64> = s.windows(2).map(|w| (w[1] - w[0]) as f64 / 1000.0).collect();
            if gaps.is_empty() {
                eprintln!("no frames painted");
            } else {
                let total: f64 = gaps.iter().sum();
                gaps.sort_by(|a, b| a.partial_cmp(b).unwrap());
                println!(
                    "painted={} in {:.1}s ({:.1} fps)  median={:.1}ms  p95={:.1}ms",
                    gaps.len(),
                    total / 1000.0,
                    gaps.len() as f64 / (total / 1000.0),
                    gaps[gaps.len() / 2],
                    gaps[(gaps.len() * 95) / 100]
                );
            }
            app.quit();
        });
    });

    app.run_with_args::<&str>(&[])
}
