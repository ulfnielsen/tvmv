//! Environment fix-ups that must happen before WebKit initialises.
//!
//! WebKitGTK confines its web processes with bubblewrap, which needs
//! unprivileged user namespaces. Some environments — containers, hardened
//! kernels — deny that, and the failure is fatal and opaque:
//!
//! ```text
//! bwrap: setting up uid map: Permission denied
//! ERROR: Failed to fully launch dbus-proxy
//! ```
//!
//! In the WebKitGTK 6.0 API the sandbox is mandatory — `set_sandbox_enabled`
//! existed in the 4.x API and is gone — so the only lever is WebKit's own
//! environment variable, which must be set before WebKit initialises.
//!
//! The opt-out is explicit. There is deliberately no auto-detection: a
//! heuristic that guessed wrong would silently drop a security boundary for
//! ordinary users, which is far worse than a clear error inside a container.

/// Turn off WebKit's sandbox when the kernel will not let it start.
///
/// WebKitGTK confines web processes with bubblewrap, which needs an
/// unprivileged user namespace. Ubuntu 24.04 sets
/// `kernel.apparmor_restrict_unprivileged_userns=1`, which denies that to
/// **unconfined** processes — and the failure is fatal and opaque:
///
/// ```text
/// bwrap: setting up uid map: Permission denied
/// ERROR: Failed to fully launch dbus-proxy: Child process exited with code 1
/// Trace/breakpoint trap
/// ```
///
/// Packaged WebKit apps avoid it with a one-line AppArmor profile granting
/// `userns` (see `linux/data/apparmor/tvmv`, modelled on Ubuntu's `epiphany`
/// profile). An uninstalled build — anything run straight out of `target/` —
/// cannot have one, so it would crash on launch every time.
///
/// **This checks the kernel's actual policy rather than guessing.** The earlier
/// version of this function refused to auto-detect, on the grounds that a wrong
/// guess would silently weaken a security boundary. That reasoning was right
/// about heuristics and wrong here: these three files say deterministically
/// whether bwrap can start, and the alternative is not "a slightly less safe
/// app", it is an app that does not run at all.
pub fn apply_opt_out() {
    if std::env::var_os("TVMV_DISABLE_SANDBOX").is_some_and(|v| v == "1") {
        disable("TVMV_DISABLE_SANDBOX=1");
        return;
    }
    if userns_blocked() {
        disable(
            "this kernel denies user namespaces to unconfined processes.\n\
             tvmv: install the AppArmor profile (linux/data/apparmor/tvmv) to run sandboxed",
        );
    }
}

fn disable(reason: &str) {
    eprintln!("tvmv: WebKit sandbox disabled — {reason}");
    // SAFETY: called before any threads are spawned, at the top of main.
    unsafe { std::env::set_var("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS", "1") };
}

/// Whether this process will be denied an unprivileged user namespace.
fn userns_blocked() -> bool {
    let read = |path: &str| std::fs::read_to_string(path).ok();
    userns_blocked_by(
        read("/proc/sys/kernel/apparmor_restrict_unprivileged_userns").as_deref(),
        read("/proc/sys/kernel/unprivileged_userns_clone").as_deref(),
        read("/proc/self/attr/apparmor/current")
            .or_else(|| read("/proc/self/attr/current"))
            .as_deref(),
    )
}

/// The decision, separated from the filesystem so it can be tested.
///
/// - `apparmor_restrict`: Ubuntu 24.04+. When `1`, only processes under an
///   AppArmor profile that grants `userns` may create one — an `unconfined`
///   label means denied.
/// - `legacy_clone`: older Debian knob. `0` denies outright.
/// - `label`: this process's AppArmor label.
fn userns_blocked_by(
    apparmor_restrict: Option<&str>,
    legacy_clone: Option<&str>,
    label: Option<&str>,
) -> bool {
    if legacy_clone.map(str::trim) == Some("0") {
        return true;
    }
    if apparmor_restrict.map(str::trim) != Some("1") {
        return false;
    }
    // Restricted: only a profiled process may proceed. A missing label file
    // means AppArmor is not labelling us, which is the unconfined case.
    match label {
        Some(l) => l.trim().starts_with("unconfined"),
        None => true,
    }
}

/// Re-enable WebKitGTK's dmabuf renderer.
///
/// Debian and Ubuntu carry `disable-dmabuf-nvidia.patch`, which disables the
/// dmabuf renderer whenever an NVIDIA proprietary driver is present. WebKit then
/// hands every frame to the UI process as a shared-memory buffer, and GTK
/// uploads all of it on the main thread. The cost scales with window area and
/// saturates a core. Measured here at 1200x1200 logical on a 5K display:
///
/// | | default | forced |
/// |---|---|---|
/// | frame rate | 19.7 fps | **61.2 fps** |
/// | median frame | 52.3 ms | **16.7 ms** (one vsync) |
/// | UI-process CPU | 109% of a core | **0.0%** |
///
/// The same patch provides this override, so no rebuild of WebKit is needed.
/// Upstream WebKit declined the disable (bug 262607, WONTFIX); it is
/// distribution-only. On any other distribution, or on non-NVIDIA hardware, the
/// variable is inert.
///
/// **Why this is opt-OUT rather than opt-in.** The patch exists because some
/// NVIDIA setups showed blank windows and flicker with the dmabuf renderer —
/// reports from 2023, on much older drivers. A blank window is a worse failure
/// than slow scrolling, so `TVMV_NO_FORCE_DMABUF=1` turns this back off for
/// anyone who hits it, and the README documents that.
///
/// Call before any WebKit type is touched.
pub fn force_dmabuf_renderer() {
    if std::env::var_os("TVMV_NO_FORCE_DMABUF").is_some_and(|v| v == "1") {
        return;
    }
    // Never override an explicit choice by the user or the desktop.
    if std::env::var_os("WEBKIT_FORCE_DMABUF_RENDERER").is_some()
        || std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_some()
    {
        return;
    }
    // SAFETY: called before any threads are spawned, at the top of main.
    unsafe { std::env::set_var("WEBKIT_FORCE_DMABUF_RENDERER", "1") };
}

#[cfg(test)]
mod tests {
    use super::userns_blocked_by;

    #[test]
    fn ubuntu_24_04_unconfined_is_blocked() {
        // The configuration that crashed on launch.
        assert!(userns_blocked_by(Some("1\n"), Some("1\n"), Some("unconfined\n")));
    }

    #[test]
    fn a_profiled_process_is_allowed() {
        // What installing the AppArmor profile buys: a real label.
        assert!(!userns_blocked_by(Some("1\n"), Some("1\n"), Some("tvmv (unconfined)\n")));
        assert!(!userns_blocked_by(Some("1\n"), None, Some("epiphany (unconfined)\n")));
    }

    #[test]
    fn unrestricted_kernel_is_allowed_even_when_unconfined() {
        assert!(!userns_blocked_by(Some("0\n"), Some("1\n"), Some("unconfined\n")));
        assert!(!userns_blocked_by(None, None, Some("unconfined\n")));
    }

    #[test]
    fn legacy_debian_knob_blocks_outright() {
        assert!(userns_blocked_by(None, Some("0\n"), Some("some-profile\n")));
    }

    /// Restricted with no label at all: AppArmor is not labelling us, which is
    /// the unconfined case, so bwrap will fail.
    #[test]
    fn restricted_without_a_label_is_blocked() {
        assert!(userns_blocked_by(Some("1\n"), None, None));
    }
}
