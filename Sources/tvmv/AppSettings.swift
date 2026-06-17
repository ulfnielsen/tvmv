import SwiftUI
import AppKit

/// Typography / display settings, persisted in UserDefaults, shared via the
/// environment. `styleJSON` emits exactly the keys boot.js `applyStyle` expects.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Theme: String, CaseIterable, Identifiable { case auto, light, dark; var id: String { rawValue } }

    @Published var bodyFont: String { didSet { d.set(bodyFont, forKey: K.bodyFont) } }
    @Published var monoFont: String { didSet { d.set(monoFont, forKey: K.monoFont) } }
    @Published var baseSize: Double { didSet { d.set(baseSize, forKey: K.baseSize) } }
    @Published var measure: Double { didSet { d.set(measure, forKey: K.measure) } }
    @Published var fullWidth: Bool { didSet { d.set(fullWidth, forKey: K.fullWidth) } }
    @Published var theme: Theme { didSet { d.set(theme.rawValue, forKey: K.theme) } }
    @Published var showOutline: Bool { didSet { d.set(showOutline, forKey: K.showOutline) } }

    private let d = UserDefaults.standard
    private enum K {
        static let bodyFont = "bodyFont", monoFont = "monoFont", baseSize = "baseSize"
        static let measure = "measure", fullWidth = "fullWidth", theme = "theme", showOutline = "showOutline"
    }

    private init() {
        bodyFont = d.string(forKey: K.bodyFont) ?? "Source Serif 4"
        monoFont = d.string(forKey: K.monoFont) ?? "Menlo"
        baseSize = d.object(forKey: K.baseSize) as? Double ?? 16
        measure = d.object(forKey: K.measure) as? Double ?? 72
        fullWidth = d.bool(forKey: K.fullWidth)            // default false
        theme = Theme(rawValue: d.string(forKey: K.theme) ?? "auto") ?? .auto
        showOutline = d.object(forKey: K.showOutline) as? Bool ?? true
    }

    func increaseFontSize() { baseSize = min(baseSize + 1, 48) }
    func decreaseFontSize() { baseSize = max(baseSize - 1, 8) }

    /// Resolve `.auto` against the current system appearance.
    var resolvedTheme: String {
        switch theme {
        case .light: return "light"
        case .dark: return "dark"
        case .auto:
            let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        }
    }

    /// JSON payload for boot.js `applyStyle` — keys match the bridge contract.
    var styleJSON: String {
        let dict: [String: Any] = [
            "bodyFont": bodyFont, "monoFont": monoFont,
            "baseSize": baseSize, "measure": measure,
            "fullWidth": fullWidth, "theme": resolvedTheme
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
