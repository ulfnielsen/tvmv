import SwiftUI
import AppKit

/// Routes app termination through each dirty window's close prompt, so ⌘Q
/// can't silently drop unsaved edits (windowShouldClose is not consulted
/// during termination otherwise). A single ⌘Q resolves every window that
/// needs it, in sequence, via `.terminateLater`: quit proceeds when all are
/// resolved and aborts on the first Cancel. Windows are found via the
/// close-guard proxy's `needsFlow` (dirty, or an open editor that can hold
/// keystrokes still inside its 100 ms debounce). `isDocumentEdited` is
/// deliberately never consulted or set — see WindowCloseGuard's doc comment.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let pending = Self.windowsNeedingResolution(sender.windows)
        guard !pending.isEmpty else { return .terminateNow }
        Task { @MainActor in
            let allResolved = await Self.resolveAll(pending)
            sender.reply(toApplicationShouldTerminate: allResolved)
        }
        return .terminateLater
    }

    /// On-screen (or miniaturized) guarded windows with unresolved edits.
    /// Closed windows linger in NSApp.windows until SwiftUI releases them —
    /// without the visibility check, quitting would resurrect and re-prompt
    /// a window the user just closed with "Don't Save".
    @MainActor
    static func windowsNeedingResolution(_ windows: [NSWindow]) -> [NSWindow] {
        windows.filter { window in
            (window.isVisible || window.isMiniaturized)
                && (window.delegate as? CloseGuardDelegate)?.needsFlow() == true
        }
    }

    /// Resolve each window in turn (flush → prompt → close); false on the
    /// first veto so termination can be aborted. Re-checks each window's
    /// state at its turn — an earlier prompt's side effects may have changed it.
    @MainActor
    static func resolveAll(_ windows: [NSWindow]) async -> Bool {
        for window in windows {
            guard window.isVisible || window.isMiniaturized,
                  let proxy = window.delegate as? CloseGuardDelegate,
                  proxy.needsFlow()
            else { continue }
            window.makeKeyAndOrderFront(nil)
            guard await proxy.resolveForQuit(window) else { return false }
        }
        return true
    }
}

@main
struct TvmvApp: App {
    // Shared settings injected into every scene's environment.
    @StateObject private var settings = AppSettings.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Read-only viewer: `viewing:` suppresses all save/edit affordances
        // (FileDocumentConfiguration.isEditable == false).
        DocumentGroup(viewing: MarkdownDocument.self) { file in
            ViewerWindow(document: file.document, fileURL: file.fileURL)
                .environmentObject(settings)
        }
        .defaultSize(width: 1260, height: 1180)
        .commands {
            ViewerMenuCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
