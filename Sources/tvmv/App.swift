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
        .commands {
            // --- Text size ---
            // CAVEAT: keyboardShortcut("+", modifiers: .command) collides with
            // Cmd+= on most keyboards: macOS reports Cmd+= for the unshifted key,
            // so "Cmd+Plus" (which requires Shift) may not fire as users expect.
            // A production app typically also binds "=" to the increase action.
            CommandGroup(after: .toolbar) {
                Button("Increase Font Size") {
                    settings.increaseFontSize()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Decrease Font Size") {
                    settings.decreaseFontSize()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Toggle Outline") {
                    settings.showOutline.toggle()
                    NotificationCenter.default.post(name: .tvmvToggleOutline, object: nil)
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            }

            // --- Find (in the standard Edit / text-editing area) ---
            CommandGroup(after: .textEditing) {
                Button("Find…") {
                    NotificationCenter.default.post(name: .tvmvFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            // --- File-level: Reload ---
            CommandGroup(after: .newItem) {
                Button("Reload") {
                    NotificationCenter.default.post(name: .tvmvReload, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            // --- Print, in the standard print slot ---
            CommandGroup(replacing: .printItem) {
                Button("Print…") {
                    NotificationCenter.default.post(name: .tvmvPrint, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
