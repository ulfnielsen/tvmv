import SwiftUI
import AppKit

/// Attaches a Save/Don't Save/Cancel prompt to the hosting window's close
/// button when there are unsaved edits, and mirrors the dirty state into the
/// titlebar dot (`isDocumentEdited`).
///
/// SwiftUI owns the window's delegate, so we install a proxy that intercepts
/// only `windowShouldClose` and forwards everything else to the original.
struct WindowCloseGuard: NSViewRepresentable {
    /// Read live from the model on each close attempt.
    var isDirty: () -> Bool
    /// Attempt to save; return true when the window may close (save succeeded
    /// or there was nothing to save).
    var save: () -> Bool

    func makeCoordinator() -> CloseGuardDelegate { CloseGuardDelegate() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let proxy = context.coordinator
        proxy.isDirty = isDirty
        proxy.save = save
        let dirty = isDirty()
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.delegate !== proxy {
                proxy.original = window.delegate
                window.delegate = proxy
            }
            window.isDocumentEdited = dirty
        }
    }
}

/// Proxy window delegate: intercepts `windowShouldClose`, forwards the rest.
@MainActor
final class CloseGuardDelegate: NSObject, NSWindowDelegate {
    /// Held strongly: NSWindow.delegate is weak, and once we replace it we may
    /// be the only thing keeping SwiftUI's delegate alive.
    ///
    /// `nonisolated(unsafe)`: `responds(to:)` and `forwardingTarget(for:)`
    /// override NSObject's nonisolated methods, so they can't inherit this
    /// class's @MainActor isolation. AppKit always invokes window-delegate
    /// forwarding on the main thread, so this is safe in practice.
    nonisolated(unsafe) var original: NSWindowDelegate?
    var isDirty: () -> Bool = { false }
    var save: () -> Bool = { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty() else {
            return original?.windowShouldClose?(sender) ?? true
        }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(sender.title)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:            // Save
            guard save() else { return false }   // save failed — keep the window
            return original?.windowShouldClose?(sender) ?? true
        case .alertThirdButtonReturn:            // Don't Save
            return original?.windowShouldClose?(sender) ?? true
        default:                                 // Cancel
            return false
        }
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}
