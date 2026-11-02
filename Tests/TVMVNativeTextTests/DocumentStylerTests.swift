import XCTest
import CoreGraphics
import TVMVCore
@testable import TVMVNativeText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class DocumentStylerTests: XCTestCase {
    private let theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16, measure: 80,
                                    fullWidth: false, dark: false)

    private func styled(_ text: String, revealed: Bool = false,
                        imageHeight: @escaping (MarkdownLayout.BlockImage) -> CGFloat? = { _ in nil }) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        DocumentStyler.apply(MarkdownLayoutParser.parse(text), to: storage,
                             in: NSRange(location: 0, length: storage.length), theme: theme,
                             isRevealed: { _ in revealed }, imageHeight: imageHeight)
        return storage
    }

    private func hidden(_ storage: NSTextStorage, _ index: Int) -> Bool {
        storage.attribute(.tvmvHidden, at: index, effectiveRange: nil) != nil
    }

    private func paragraph(_ storage: NSTextStorage, _ index: Int) -> NSParagraphStyle? {
        storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }

    func testDelimitersHide() {
        let storage = styled("Some **bold** text")
        for i in [5, 6, 11, 12] { XCTAssertTrue(hidden(storage, i), "delimiter at \(i)") }
        XCTAssertFalse(hidden(storage, 7))
        let font = storage.attribute(.font, at: 7, effectiveRange: nil) as? PlatformFont
        #if os(macOS)
        XCTAssertEqual(font?.fontDescriptor.symbolicTraits.contains(.bold), true)
        #else
        XCTAssertEqual(font?.fontDescriptor.symbolicTraits.contains(.traitBold), true)
        #endif
    }

    func testRevealedUnitShowsMarkup() {
        let storage = styled("Some **bold** text", revealed: true)
        for i in 0..<storage.length { XCTAssertFalse(hidden(storage, i), "index \(i)") }
    }

    func testFenceLinesCollapse() {
        let storage = styled("Para\n\n```\ncode\n```\n")
        XCTAssertTrue(hidden(storage, 6))
        XCTAssertEqual(paragraph(storage, 6)?.maximumLineHeight, 0.01)
    }

    func testBlockImageReservesHeight() {
        let storage = styled("![a](x.png)\n", imageHeight: { _ in 100 })
        XCTAssertEqual(paragraph(storage, 0)?.minimumLineHeight, 100 + 16)
    }
}
