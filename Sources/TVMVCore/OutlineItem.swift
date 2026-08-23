import Foundation

/// One heading in the document outline. `anchor` is the slug id assigned in JS.
public struct OutlineItem: Identifiable, Sendable, Equatable {
    public var level: Int
    public var title: String
    public var anchor: String
    public var id: String { anchor }

    public init(level: Int, title: String, anchor: String) {
        self.level = level
        self.title = title
        self.anchor = anchor
    }
}
