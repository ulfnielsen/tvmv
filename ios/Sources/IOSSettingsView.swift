import SwiftUI
import TVMVCore

struct IOSSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading") {
                    TextField("Body font", text: $settings.bodyFont)
                    TextField("Code font", text: $settings.monoFont)
                    Stepper("Size: \(Int(settings.baseSize)) pt",
                            value: $settings.baseSize, in: 8...48)
                    Stepper("Measure: \(Int(settings.measure)) ch",
                            value: $settings.measure, in: 40...120)
                    Toggle("Full width", isOn: $settings.fullWidth)
                }
                Section("Theme") {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(AppSettings.Theme.allCases) {
                            Text($0.rawValue.capitalized).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
