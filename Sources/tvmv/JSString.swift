import Foundation

/// JSON-encode a Swift string into a safe JS string literal, for building
/// `evaluateJavaScript` calls. Shared by the preview and editor bridges.
enum JSString {
    static func literal(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\"\""
    }
}
