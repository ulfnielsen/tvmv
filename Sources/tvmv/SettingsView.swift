import SwiftUI
import AppKit

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
        }
        .padding(20)
        .frame(width: 380)
    }
}
