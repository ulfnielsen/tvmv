import XCTest
import CoreGraphics
import TVMVCore
@testable import TVMVNativeText
#if os(macOS)
import AppKit
#endif

final class NativeThemeTests: XCTestCase {
    private func theme(fullWidth: Bool = false, dark: Bool = false) -> NativeTheme {
        NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16, measure: 80,
                    fullWidth: fullWidth, dark: dark)
    }

    func testFullWidthHasNoColumn() {
        XCTAssertNil(theme(fullWidth: true).columnWidth)
        XCTAssertNotNil(theme().columnWidth)
    }

    func testHeadingScale() {
        let t = theme()
        XCTAssertEqual(t.headingFont(1).pointSize, 32, accuracy: 0.01)
        XCTAssertEqual(t.headingFont(6).pointSize, 13.6, accuracy: 0.01)
    }

    func testDarkPaperAndChrome() throws {
        let t = theme(dark: true)
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let c = try XCTUnwrap(t.paper.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil)?.components)
        XCTAssertEqual(c[0], CGFloat(0x18) / 255, accuracy: 0.002)
        XCTAssertEqual(c[1], CGFloat(0x14) / 255, accuracy: 0.002)
        XCTAssertEqual(c[2], CGFloat(0x10) / 255, accuracy: 0.002)

        let expected = RGBAColor(red: Double(0x18) / 255, green: Double(0x14) / 255, blue: Double(0x10) / 255)
            .blended(fraction: 0.16, of: .white)
        XCTAssertEqual(t.chromeColor.red, expected.red, accuracy: 0.002)
        XCTAssertEqual(t.chromeColor.green, expected.green, accuracy: 0.002)
        XCTAssertEqual(t.chromeColor.blue, expected.blue, accuracy: 0.002)
    }

    func testAddingTraits() {
        let bold = PlatformFont.systemFont(ofSize: 14).adding(.bold)
        #if os(macOS)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        #else
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        #endif
    }
}
