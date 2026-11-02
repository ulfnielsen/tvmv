import XCTest
import CoreGraphics
import TVMVCore
@testable import TVMVNativeText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class MarkupLayoutDelegateTests: XCTestCase {
    private let theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16, measure: 80,
                                    fullWidth: false, dark: false)
    private let delegate = MarkupLayoutDelegate()

    private func stack(_ text: String) -> (NSTextStorage, NSLayoutManager) {
        let storage = NSTextStorage(string: text)
        // Styled first: glyphs are generated once, with the attributes in place.
        DocumentStyler.apply(MarkdownLayoutParser.parse(text), to: storage,
                             in: NSRange(location: 0, length: storage.length), theme: theme,
                             isRevealed: { _ in false }, imageHeight: { _ in nil })
        let lm = NSLayoutManager()
        lm.delegate = delegate
        storage.addLayoutManager(lm)
        lm.addTextContainer(NSTextContainer(size: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude)))
        return (storage, lm)
    }

    private func x(_ lm: NSLayoutManager, _ character: Int) -> CGFloat {
        lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: character)).x
    }

    func testHiddenCharactersAreNullGlyphs() {
        let (storage, lm) = stack("Some **bold** text")
        defer { withExtendedLifetime(storage) {} }   // the layout manager holds its storage weakly
        lm.ensureLayout(for: lm.textContainers[0])
        XCTAssertEqual(lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: 5)), .null)
        XCTAssertEqual(x(lm, 7), x(lm, 5), accuracy: 0.5)
    }

    func testSoftBreakIsASpace() {
        let (storage, lm) = stack("one\ntwo\n")
        lm.ensureLayout(for: lm.textContainers[0])
        XCTAssertNotNil(storage.attribute(.tvmvSoftBreak, at: 3, effectiveRange: nil))
        let first = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: 0), effectiveRange: nil)
        let second = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: 4), effectiveRange: nil)
        XCTAssertEqual(first, second)
        let font = storage.attribute(.font, at: 2, effectiveRange: nil) as! PlatformFont
        let eWidth = ("e" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThan(x(lm, 4) - x(lm, 2), eWidth)
    }
}
