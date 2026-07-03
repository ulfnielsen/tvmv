import SwiftUI
import AppKit

/// Routes app termination through each dirty window's close prompt, so ⌘Q
/// can't silently drop unsaved edits (windowShouldClose is not consulted
/// during termination otherwise).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for window in sender.windows where window.isDocumentEdited {
            window.makeKeyAndOrderFront(nil)
            let mayClose = window.delegate?.windowShouldClose?(window) ?? true
            if !mayClose { return .terminateCancel }
        }
        return .terminateNow
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
