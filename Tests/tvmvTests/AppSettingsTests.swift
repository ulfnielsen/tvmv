import XCTest
@testable import tvmv

@MainActor
final class AppSettingsTests: XCTestCase {
    /// A settings instance backed by a throwaway UserDefaults suite, so tests
    /// never read or write the real app's persisted preferences.
    private static func isolated() -> AppSettings {
        let name = "tvmv.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return AppSettings(defaults: suite)
    }

    func testStyleJSONHasBootKeys() throws {
        let s = Self.isolated()
        s.bodyFont = "Source Serif 4"; s.monoFont = "Menlo"
        s.baseSize = 16; s.measure = 72; s.fullWidth = false; s.theme = .light
        let data = Data(s.styleJSON.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["bodyFont"] as? String, "Source Serif 4")
        XCTAssertEqual(obj["monoFont"] as? String, "Menlo")
        XCTAssertEqual(obj["baseSize"] as? Double, 16)
        XCTAssertEqual(obj["measure"] as? Double, 72)
        XCTAssertEqual(obj["fullWidth"] as? Bool, false)
        XCTAssertEqual(obj["theme"] as? String, "light")
    }
    func testEditorStyleJSONFollowsCodeFontUntilOverridden() throws {
        let s = Self.isolated()
        s.monoFont = "Menlo"; s.baseSize = 14; s.theme = .light

        // Default: empty editorFont means "same as code font".
        var obj = try JSONSerialization.jsonObject(
            with: Data(s.editorStyleJSON.utf8)) as! [String: Any]
        XCTAssertEqual(obj["monoFont"] as? String, "Menlo")

        // Overridden: the dedicated editor font wins.
        s.editorFont = "SF Mono"
        obj = try JSONSerialization.jsonObject(
            with: Data(s.editorStyleJSON.utf8)) as! [String: Any]
        XCTAssertEqual(obj["monoFont"] as? String, "SF Mono")
        XCTAssertEqual(obj["baseSize"] as? Double, 14)
        XCTAssertEqual(obj["theme"] as? String, "light")
    }
    func testFontSizeClamps() {
        let s = Self.isolated()
        s.baseSize = 8; s.decreaseFontSize(); XCTAssertEqual(s.baseSize, 8)
        s.baseSize = 48; s.increaseFontSize(); XCTAssertEqual(s.baseSize, 48)
    }
}
