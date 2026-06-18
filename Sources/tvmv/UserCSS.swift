import Foundation

/// User-supplied CSS override. The file is chosen in Settings (or the default
/// `~/.config/tvmv/custom.css`); see `AppSettings.customCSSURL`.
///
/// When present, its contents are injected into the rendered page AFTER the
/// built-in theme (and lazily-loaded vendor styles), so it can override fonts,
/// colors, spacing — anything. Edit the file and it live-reloads (the viewer
/// watches it). Override the typography *variables* (`--tvmv-…`) with
/// `!important`, since the app sets them inline for live Settings updates.
enum UserCSS {
    /// The stylesheet contents at `url`, or `nil` if absent/unreadable.
    static func load(_ url: URL?) -> String? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
