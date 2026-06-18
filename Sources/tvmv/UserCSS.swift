import Foundation

/// User-supplied CSS override, loaded from `~/.config/tvmv/custom.css`.
///
/// When present, its contents are injected into the rendered page AFTER the
/// built-in theme (and lazily-loaded vendor styles), so it can override fonts,
/// colors, spacing — anything. Edit the file and it live-reloads (the viewer
/// watches it). Absent file => no override.
enum UserCSS {
    /// `~/.config/tvmv/custom.css`
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tvmv/custom.css")
    }

    /// The stylesheet contents, or `nil` if the file is absent/unreadable.
    static func load() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
