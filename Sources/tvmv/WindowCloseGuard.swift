import SwiftUI
import AppKit

/// Attaches a Save/Don't Save/Cancel prompt to the hosting window's close
/// button when there are unsaved edits.
///
/// Deliberately does NOT touch `window.isDocumentEdited`: in a
/// `DocumentGroup(viewing:)` app the document is unwritable, and marking the
/// window edited recruits AppKit/SwiftUI's own unsaved-document machinery,
/// which then fails to autosave and stacks its own "cannot autosave" alerts
/// around ours. The dirty indicator is a SwiftUI `navigationSubtitle` instead.
///
/// SwiftUI owns the window's delegate, so we install a proxy that intercepts
/// only `windowShouldClose` and forwards everything else to the original.
///
/// The dirty path is ASYNC: a correct dirty check must first flush the
/// CodeMirror bridge (keystrokes inside its 100 ms debounce window), which
/// cannot happen synchronously inside windowShouldClose. So the delegate
/// defers the close (returns false), flushes, prompts if still dirty, then
/// re-closes with an approval flag. Clean, non-editing windows keep the old
/// synchronous fast path.
struct WindowCloseGuard: NSViewRepresentable {
    /// True when the async flow is needed (dirty, or the editor pane is open
    /// and may hold unflushed keystrokes).
    var needsFlow: () -> Bool
    /// Pull authoritative text from the editor into the model.
    var flush: () async -> Void
    /// Read live from the model after the flush.
    var isDirty: () -> Bool
    /// Attempt to save; return true when the window may close.
    var save: () -> Bool

    func makeCoordinator() -> CloseGuardDelegate { CloseGuardDelegate() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let proxy = context.coordinator
        proxy.needsFlow = needsFlow
        proxy.flush = flush
        proxy.isDirty = isDirty
        proxy.save = save
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.delegate !== proxy {
                proxy.original = window.delegate
                window.delegate = proxy
            }
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
    var needsFlow: () -> Bool = { false }
    var flush: () async -> Void = {}
    var isDirty: () -> Bool = { false }
    var save: () -> Bool = { true }
    /// Set by the async flow just before it re-triggers the close; consumed
    /// (and reset) by the next windowShouldClose so the close proceeds.
    private var closeApproved = false
    /// True while the async flow (flush → prompt → re-close) is running, so a
    /// second close attempt can't spawn a concurrent flow (double flush,
    /// stacked alerts, double performClose). Cleared on every flow exit.
    private var flowInFlight = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeApproved {
            closeApproved = false
            return original?.windowShouldClose?(sender) ?? true
        }
        guard needsFlow() else {
            return original?.windowShouldClose?(sender) ?? true
        }
        if flowInFlight { return false }
        flowInFlight = true
        Task { @MainActor [weak self, weak sender] in
            guard let self, let window = sender else { return }
            defer { self.flowInFlight = false }
            await self.flush()
            guard self.isDirty() else {
                self.approveAndClose(window)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Do you want to save the changes made to “\(window.title)”?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn:            // Save
                if self.save() { self.approveAndClose(window) }
                // Save failed: stay open; the model's saveError alert explains.
            case .alertThirdButtonReturn:            // Don't Save
                self.approveAndClose(window)
            default:                                 // Cancel
                break
            }
        }
        return false
    }

    /// Re-run the close with approval set; performClose (not close()) so the
    /// original SwiftUI delegate is still consulted on the approved pass.
    private func approveAndClose(_ window: NSWindow) {
        closeApproved = true
        window.performClose(nil)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}
