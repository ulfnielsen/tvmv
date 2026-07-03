import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    private let families = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            Picker("Body font", selection: $settings.bodyFont) {
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            Picker("Code font", selection: $settings.monoFont) {
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            Picker("Editor font", selection: $settings.editorFont) {
                Text("Same as code font").tag("")
                Divider()
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            // Follows the base size until first touched; 0 = "not overridden".
            Stepper(value: editorSize, in: 8...48, step: 1) {
                HStack {
                    Text(settings.editorFontSize > 0
                        ? "Editor size: \(Int(settings.editorFontSize)) pt"
                        : "Editor size: base (\(Int(settings.baseSize)) pt)")
                    if settings.editorFontSize > 0 {
                        Button("Match base") { settings.editorFontSize = 0 }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            Stepper(value: $settings.baseSize, in: 8...48, step: 1) {
                Text("Base size: \(Int(settings.baseSize)) pt")
            }
            Toggle("Full width", isOn: $settings.fullWidth)
            if !settings.fullWidth {
                Stepper(value: $settings.measure, in: 40...120, step: 2) {
                    Text("Measure: \(Int(settings.measure)) ch")
                }
            }
            Picker("Theme", selection: $settings.theme) {
                ForEach(AppSettings.Theme.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)

            Divider()
            LabeledContent("Custom CSS") {
                Text(cssLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Button("Choose…") { chooseCSS() }
                if !settings.customCSSPath.isEmpty {
                    Button("Reset to default") { settings.customCSSPath = "" }
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    /// Stepping from the "follow base size" state starts from the base value.
    private var editorSize: Binding<Double> {
        Binding(
            get: { settings.editorFontSize > 0 ? settings.editorFontSize : settings.baseSize },
            set: { settings.editorFontSize = $0 }
        )
    }

    private var cssLabel: String {
        settings.customCSSPath.isEmpty ? "none" : (settings.customCSSPath as NSString).lastPathComponent
    }

    private func chooseCSS() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose a CSS theme"
        if let css = UTType(filenameExtension: "css") { panel.allowedContentTypes = [css] }
        if panel.runModal() == .OK, let url = panel.url {
            settings.customCSSPath = url.path
        }
    }
}
