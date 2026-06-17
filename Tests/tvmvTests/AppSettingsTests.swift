import XCTest
@testable import tvmv

@MainActor
final class AppSettingsTests: XCTestCase {
    func testStyleJSONHasBootKeys() throws {
        let s = AppSettings.shared
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
    func testFontSizeClamps() {
        let s = AppSettings.shared
        s.baseSize = 8; s.decreaseFontSize(); XCTAssertEqual(s.baseSize, 8)
        s.baseSize = 48; s.increaseFontSize(); XCTAssertEqual(s.baseSize, 48)
    }
}
