//! The desktop's light/dark preference, read from the XDG portal.
//!
//! Replaces GTK's `gtk-application-prefer-dark-theme`, which is **not a reliable
//! signal**: `GTK_THEME=Adwaita:dark` does not set it, so `theme: auto` stayed
//! light under a dark GTK theme. The portal's `org.freedesktop.appearance`
//! `color-scheme` is the cross-desktop answer, and it is also what makes this
//! correct on KDE and XFCE rather than only where GTK's own setting happens to
//! be maintained.

use gtk4::gio;
use gtk4::prelude::*;

const PORTAL_NAME: &str = "org.freedesktop.portal.Desktop";
const PORTAL_PATH: &str = "/org/freedesktop/portal/desktop";
const SETTINGS_IFACE: &str = "org.freedesktop.portal.Settings";
const NAMESPACE: &str = "org.freedesktop.appearance";
const KEY: &str = "color-scheme";

/// The portal's `color-scheme` values.
///
/// 0 = no preference, 1 = prefer dark, 2 = prefer light. Anything else is a
/// value from a newer spec than this build knows, and must not be guessed at —
/// treat it as no preference.
pub fn prefers_dark_from_color_scheme(value: u32) -> Option<bool> {
    match value {
        1 => Some(true),
        2 => Some(false),
        _ => None,
    }
}

/// Whether the desktop is asking for a dark appearance.
///
/// Falls back to GTK's setting when the portal is unavailable (no portal
/// running, or a session without one) rather than assuming light.
pub fn prefers_dark() -> bool {
    portal_color_scheme()
        .and_then(prefers_dark_from_color_scheme)
        .unwrap_or_else(gtk_prefers_dark)
}

fn gtk_prefers_dark() -> bool {
    gtk4::Settings::default().map(|s| s.is_gtk_application_prefer_dark_theme()).unwrap_or(false)
}

fn settings_proxy() -> Option<gio::DBusProxy> {
    gio::DBusProxy::for_bus_sync(
        gio::BusType::Session,
        gio::DBusProxyFlags::NONE,
        None,
        PORTAL_NAME,
        PORTAL_PATH,
        SETTINGS_IFACE,
        gio::Cancellable::NONE,
    )
    .ok()
}

fn portal_color_scheme() -> Option<u32> {
    let proxy = settings_proxy()?;

    // `ReadOne` (portal 2+) returns the value directly; `Read` wraps it in an
    // extra variant. Try the newer call first and fall back, because a desktop
    // that only has the old one is common enough to matter.
    let one = proxy.call_sync(
        "ReadOne",
        Some(&(NAMESPACE, KEY).to_variant()),
        gio::DBusCallFlags::NONE,
        1000,
        gio::Cancellable::NONE,
    );
    if let Ok(reply) = one
        && let Some(value) = unwrap_variant(&reply)
    {
        return value;
    }

    let read = proxy
        .call_sync(
            "Read",
            Some(&(NAMESPACE, KEY).to_variant()),
            gio::DBusCallFlags::NONE,
            1000,
            gio::Cancellable::NONE,
        )
        .ok()?;
    unwrap_variant(&read)?
}

/// Peel the reply tuple and any nested variants down to a `u32`.
fn unwrap_variant(reply: &gtk4::glib::Variant) -> Option<Option<u32>> {
    // `Read` returns v(v(u)); `ReadOne` returns v(u). Unwrap until it is no
    // longer a variant rather than assuming a depth — but test the type first:
    // calling `get::<Variant>()` on a non-variant logs a GLib critical.
    Some(unwrap_nested(reply.child_value(0)).get::<u32>())
}

/// Peel nested `v` wrappers off a variant.
fn unwrap_nested(mut value: gtk4::glib::Variant) -> gtk4::glib::Variant {
    while value.is_type(gtk4::glib::VariantTy::VARIANT) {
        match value.get::<gtk4::glib::Variant>() {
            Some(inner) => value = inner,
            None => break,
        }
    }
    value
}

/// Call `on_change` whenever the desktop's preference changes.
///
/// Returns the subscription; dropping it unsubscribes.
pub fn watch(on_change: impl Fn(bool) + 'static) -> Option<gio::DBusProxy> {
    let proxy = settings_proxy()?;
    proxy.connect_local("g-signal", false, move |args| {
        // (proxy, sender, signal_name, parameters)
        let signal = args.get(2).and_then(|v| v.get::<String>().ok())?;
        if signal != "SettingChanged" {
            return None;
        }
        let params = args.get(3).and_then(|v| v.get::<gtk4::glib::Variant>().ok())?;
        if params.child_value(0).get::<String>().as_deref() != Some(NAMESPACE)
            || params.child_value(1).get::<String>().as_deref() != Some(KEY)
        {
            return None;
        }
        let value = unwrap_nested(params.child_value(2));
        if let Some(dark) = value.get::<u32>().and_then(prefers_dark_from_color_scheme) {
            on_change(dark);
        }
        None
    });
    Some(proxy)
}

#[cfg(test)]
mod tests {
    use super::prefers_dark_from_color_scheme;

    #[test]
    fn maps_the_documented_values() {
        assert_eq!(prefers_dark_from_color_scheme(1), Some(true)); // prefer dark
        assert_eq!(prefers_dark_from_color_scheme(2), Some(false)); // prefer light
    }

    /// 0 is "no preference", and anything higher comes from a newer spec than
    /// this build knows. Neither may be guessed at — both fall through to the
    /// caller's own default.
    #[test]
    fn no_preference_and_unknown_values_defer() {
        assert_eq!(prefers_dark_from_color_scheme(0), None);
        assert_eq!(prefers_dark_from_color_scheme(3), None);
        assert_eq!(prefers_dark_from_color_scheme(u32::MAX), None);
    }
}
