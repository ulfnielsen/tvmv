import TVMVCore
import SwiftUI
import AppKit
import WebKit

/// NSViewRepresentable wrapping the editor WKWebView (a second, dedicated
/// web view — the preview's pipeline is untouched). All bridge logic lives in
/// TVMVCore's EditorCoordinator/EditorBridge; this shell only supplies the
/// AppKit web view (with its undo decoy) and the platform lifecycle.
struct CodeMirrorEditorPane: NSViewRepresentable {
    /// Base directory of bundled web resources (the `web/` folder).
    let appWebDir: URL
    var callbacks: EditorBridgeCallbacks = .init()
    var onMakeBridge: (@MainActor (EditorBridge) -> Void)?

    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(callbacks: callbacks) }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let webView = EditorWebView(
            frame: .zero,
            configuration: coordinator.makeConfiguration(appWebDir: appWebDir))
        let bridge = coordinator.attach(webView)
        onMakeBridge?(bridge)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.callbacks = callbacks
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: EditorCoordinator) {
        coordinator.detach(nsView)
    }

    /// WKWebView whose undo registrations never leave the view.
    ///
    /// WebKit registers a native undo action for every edit in editable
    /// content with `self.undoManager`, which by default resolves up the
    /// responder chain to the window — and in a document window, to the
    /// document's undo manager. Each registration increments the document's
    /// change count, so SwiftUI's DocumentGroup bridge believed the (unwritable,
    /// `viewing:`) document had unsaved changes and tried to autosave it on
    /// quit, failing with "could not be autosaved" alerts around our own
    /// prompt. CodeMirror manages real undo itself in JS; the native
    /// registrations are decoys, so they go into a private manager instead.
    private final class EditorWebView: WKWebView {
        private let sandboxedUndoManager = UndoManager()
        override var undoManager: UndoManager? { sandboxedUndoManager }
    }
}
