import TVMVCore
import SwiftUI

/// Per-window menu actions. The focused viewer window publishes these via
/// `focusedSceneValue`, so menu commands (Find, Print, Reload, Toggle Outline, markup)
/// act only on the frontmost window — not on every open window.
struct ViewerCommands {
    var find: () -> Void
    var printDocument: () -> Void
    var reload: () -> Void
    var toggleOutline: () -> Void
    var toggleEditing: () -> Void
    var save: () -> Void
    /// ⌘': show the markup of the span under the selection (again: hide it).
    var revealMarkup: () -> Void
    /// ⌥⌘M: show all markup.
    var showMarkdown: () -> Void
    var bold: () -> Void
    var italic: () -> Void
    /// Enables ⌘S: there are unsaved edits and a file to write to.
    var canSave: Bool
    /// Enables ⌘E: the document has a file URL to save back to.
    var canEdit: Bool
    /// Enables ⌘B/⌘I, which write markup into the text.
    var isEditing: Bool
}

struct ViewerCommandsKey: FocusedValueKey {
    typealias Value = ViewerCommands
}

extension FocusedValues {
    var viewerCommands: ViewerCommands? {
        get { self[ViewerCommandsKey.self] }
        set { self[ViewerCommandsKey.self] = newValue }
    }
}

/// The app's menu commands. Per-window actions dispatch to the focused window's
/// `ViewerCommands` (nil → disabled when no document window is frontmost). Font
/// size is a global preference, so it stays on `AppSettings.shared`.
struct ViewerMenuCommands: Commands {
    @FocusedValue(\.viewerCommands) private var commands

    var body: some Commands {
        // CAVEAT: keyboardShortcut("+", modifiers: .command) collides with Cmd+=
        // on most keyboards; a production app usually also binds "=" to increase.
        CommandGroup(after: .toolbar) {
            Button("Increase Font Size") { AppSettings.shared.increaseFontSize() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Decrease Font Size") { AppSettings.shared.decreaseFontSize() }
                .keyboardShortcut("-", modifiers: .command)
            Divider()
            Button("Toggle Outline") { commands?.toggleOutline() }
                .keyboardShortcut("0", modifiers: [.command, .shift])
                .disabled(commands == nil)
            Button("Toggle Editing") { commands?.toggleEditing() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(commands?.canEdit != true)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { commands?.find() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(commands == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Save") { commands?.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(commands?.canSave != true)
            Divider()
            Button("Reload") { commands?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(commands == nil)
        }
        CommandGroup(replacing: .textFormatting) {
            Button("Bold") { commands?.bold() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(commands?.isEditing != true)
            Button("Italic") { commands?.italic() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(commands?.isEditing != true)
            Divider()
            Button("Reveal Markup Here") { commands?.revealMarkup() }
                .keyboardShortcut("'", modifiers: .command)
                .disabled(commands == nil)
            Button("Show Markdown") { commands?.showMarkdown() }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(commands == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { commands?.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(commands == nil)
        }
    }
}
