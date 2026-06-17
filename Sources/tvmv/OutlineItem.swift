import Foundation

/// One heading in the document outline. `anchor` is the slug id assigned in JS.
struct OutlineItem: Identifiable, Sendable, Equatable {
    var level: Int
    var title: String
    var anchor: String
    var id: String { anchor }
}
