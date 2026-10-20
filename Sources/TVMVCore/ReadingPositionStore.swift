import Foundation

/// Per-file reading position and bookmark for the native view, stored as a
/// UTF-16 character offset (survives edits and resizes). Older builds stored
/// a scroll fraction under other keys; those are read as a fallback until the
/// first offset is written.
public struct ReadingPositionStore {
    public enum Position: Equatable, Sendable {
        case offset(Int)
        /// Legacy scroll fraction, 0...1.
        case fraction(Double)
    }

    private let defaults: UserDefaults
    private let path: String

    public init(fileURL: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.path = fileURL.standardizedFileURL.path
    }

    private var readingOffsetKey: String { "readingOffset.\(path)" }
    private var bookmarkOffsetKey: String { "bookmarkOffset.\(path)" }
    private var legacyReadingKey: String { "readingPosition.\(path)" }
    private var legacyBookmarkKey: String { "bookmark.\(path)" }

    public var readingPosition: Position? { position(offsetKey: readingOffsetKey, legacyKey: legacyReadingKey) }
    public var bookmark: Position? { position(offsetKey: bookmarkOffsetKey, legacyKey: legacyBookmarkKey) }

    public func setReadingOffset(_ offset: Int) { defaults.set(offset, forKey: readingOffsetKey) }
    public func setBookmarkOffset(_ offset: Int) { defaults.set(offset, forKey: bookmarkOffsetKey) }
    /// Remove the bookmark: the offset and any legacy fraction behind it.
    public func clearBookmark() {
        defaults.removeObject(forKey: bookmarkOffsetKey)
        defaults.removeObject(forKey: legacyBookmarkKey)
    }

    private func position(offsetKey: String, legacyKey: String) -> Position? {
        if let offset = defaults.object(forKey: offsetKey) as? Int { return .offset(offset) }
        if let fraction = defaults.object(forKey: legacyKey) as? Double { return .fraction(fraction) }
        return nil
    }
}
