import Foundation

/// Locates the bundled `web/` resource directory at runtime.
///
/// ## Why not `Bundle.module`?
///
/// SwiftPM's generated `Bundle.module` accessor hard-codes a search for the
/// resource bundle at the *root* of the surrounding `.app` (i.e.
/// `tvmv.app/tvmv_tvmv.bundle`). That is wrong for two independent reasons in a
/// hand-assembled application bundle:
///
///   1. **Placement.** The canonical home for resources is
///      `Contents/Resources/`, not the bundle root.
///   2. **Code signing.** `codesign` seals the bundle by hashing everything
///      under `Contents/`. *Any* file sitting at the `.app` root other than
///      `Contents/` causes "unsealed contents present in the bundle root" and
///      the signature fails. So we cannot satisfy `Bundle.module` and ship a
///      signable app at the same time.
///
/// Resolution: copy the SwiftPM-produced `tvmv_tvmv.bundle` into
/// `Contents/Resources/` (codesigns clean) and open it explicitly with
/// `Bundle(url:)`. A flat directory bundle needs no Info.plist of its own to be
/// opened this way.
enum WebResources {

    /// Name SwiftPM gives the resource bundle: `<PackageName>_<TargetName>`.
    private static let resourceBundleName = "tvmv_tvmv.bundle"

    /// URL of the bundled `web/` directory.
    ///
    /// Resolution order:
    ///   1. Canonical: open `Contents/Resources/tvmv_tvmv.bundle` via
    ///      `Bundle(url:)` and append `web`.
    ///   2. Fallback: build the path directly off `Bundle.main.resourceURL`
    ///      (covers cases where `Bundle(url:)` returns nil).
    ///   3. Dev fallback for `swift run`: the loose `.bundle` SwiftPM drops next
    ///      to the executable in `.build/.../`.
    static let baseURL: URL = {
        // 1. Canonical: explicit Bundle(url:) into Contents/Resources.
        if let resources = Bundle.main.resourceURL {
            let bundleURL = resources.appendingPathComponent(resourceBundleName)
            if let bundle = Bundle(url: bundleURL),
               let web = bundle.resourceURL?.appendingPathComponent("web"),
               FileManager.default.fileExists(atPath: web.path) {
                return web
            }

            // 2. Direct path fallback off resourceURL.
            let direct = resources
                .appendingPathComponent(resourceBundleName)
                .appendingPathComponent("web")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
        }

        // 3. Dev fallback: `swift run` places tvmv_tvmv.bundle beside the
        // executable rather than inside a Resources/ dir.
        let besideExecutable = Bundle.main.bundleURL
            .appendingPathComponent(resourceBundleName)
            .appendingPathComponent("web")
        if FileManager.default.fileExists(atPath: besideExecutable.path) {
            return besideExecutable
        }

        // Nothing matched: return the canonical location so callers fail with a
        // clear "file not found" against the expected path rather than a crash.
        return (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent(resourceBundleName)
            .appendingPathComponent("web")
    }()
}
