import SwiftUI
import AppKit

@main
struct TvmvApp: App {
    // Shared settings injected into every scene's environment.
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        // Read-only viewer: `viewing:` suppresses all save/edit affordances
        // (FileDocumentConfiguration.isEditable == false).
        DocumentGroup(viewing: MarkdownDocument.self) { file in
            ViewerWindow(document: file.document, fileURL: file.fileURL)
                .environmentObject(settings)
        }
        .defaultSize(width: 1040, height: 1180)
        .commands {
            ViewerMenuCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
