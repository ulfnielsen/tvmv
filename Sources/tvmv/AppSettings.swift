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
    @Published var customCSSPath: String { didSet { d.set(customCSSPath, forKey: K.customCSSPath) } }
    @Published var editorPaneWidth: Double { didSet { d.set(editorPaneWidth, forKey: K.editorPaneWidth) } }
    /// Editor-pane font family. Empty means "same as the code font".
    @Published var editorFont: String { didSet { d.set(editorFont, forKey: K.editorFont) } }
    /// Editor-pane font size in points. 0 means "same as the base size".
    @Published var editorFontSize: Double { didSet { d.set(editorFontSize, forKey: K.editorFontSize) } }

    private let d: UserDefaults
    private enum K {
        static let bodyFont = "bodyFont", monoFont = "monoFont", baseSize = "baseSize"
        static let measure = "measure", fullWidth = "fullWidth", theme = "theme", showOutline = "showOutline"
        static let customCSSPath = "customCSSPath"
        static let editorPaneWidth = "editorPaneWidth"
        static let editorFont = "editorFont"
        static let editorFontSize = "editorFontSize"
    }

    /// The custom-CSS file chosen in Settings, or `nil` for no override (the
    /// built-in theme). Nothing is loaded unless the user explicitly picks a file.
    var customCSSURL: URL? {
        customCSSPath.isEmpty ? nil : URL(fileURLWithPath: (customCSSPath as NSString).expandingTildeInPath)
    }

    /// `defaults` is injectable so tests can use an ephemeral suite and never
    /// touch the real app's persisted settings.
    init(defaults: UserDefaults = .standard) {
        d = defaults
        bodyFont = defaults.string(forKey: K.bodyFont) ?? "Source Serif 4"
        monoFont = defaults.string(forKey: K.monoFont) ?? "Menlo"
        baseSize = defaults.object(forKey: K.baseSize) as? Double ?? 16
        measure = defaults.object(forKey: K.measure) as? Double ?? 80
        fullWidth = defaults.bool(forKey: K.fullWidth)            // default false
        theme = Theme(rawValue: defaults.string(forKey: K.theme) ?? "auto") ?? .auto
        showOutline = defaults.object(forKey: K.showOutline) as? Bool ?? true
        customCSSPath = defaults.string(forKey: K.customCSSPath) ?? ""
        editorPaneWidth = defaults.object(forKey: K.editorPaneWidth) as? Double ?? 0
        editorFont = defaults.string(forKey: K.editorFont) ?? ""
        editorFontSize = defaults.object(forKey: K.editorFontSize) as? Double ?? 0
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

    /// JSON payload for editor.js `applyStyle` — the editor pane needs only
    /// a font family, size, and resolved theme. Dedicated editor overrides
    /// win when set; otherwise the editor follows the code font / base size.
    var editorStyleJSON: String {
        let dict: [String: Any] = [
            "monoFont": editorFont.isEmpty ? monoFont : editorFont,
            "baseSize": editorFontSize > 0 ? editorFontSize : baseSize,
            "theme": resolvedTheme
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
