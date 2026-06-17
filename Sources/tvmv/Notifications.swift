import Foundation

/// Menu commands are delivered as notifications rather than threaded focused
/// values, keeping the app shell and the per-window view decoupled.
extension Notification.Name {
    static let tvmvFind = Notification.Name("tvmv.find")
    static let tvmvPrint = Notification.Name("tvmv.print")
    static let tvmvToggleOutline = Notification.Name("tvmv.toggleOutline")
    static let tvmvReload = Notification.Name("tvmv.reload")
}
