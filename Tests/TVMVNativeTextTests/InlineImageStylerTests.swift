import XCTest
import CoreGraphics
import TVMVCore
@testable import TVMVNativeText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class InlineImageStylerTests: XCTestCase {
    private let theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16, measure: 80,
                                    fullWidth: false, dark: false)
    private let delegate = MarkupLayoutDelegate()

    private func stack(_ text: String, size: CGSize? = nil,
                       blockImagesInline: Bool = false) -> (NSTextStorage, NSLayoutManager) {
        let storage = NSTextStorage(string: text)
        // Styled first: glyphs are generated once, with the attributes in place.
        DocumentStyler.apply(MarkdownLayoutParser.parse(text), to: storage,
                             in: NSRange(location: 0, length: storage.length), theme: theme,
                             isRevealed: { _ in false }, inlineImageSize: { _ in size },
                             blockImagesInline: blockImagesInline)
        let lm = NSLayoutManager()
        lm.delegate = delegate
        storage.addLayoutManager(lm)
        lm.addTextContainer(NSTextContainer(size: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude)))
        lm.ensureLayout(for: lm.textContainers[0])
        return (storage, lm)
    }

    private func x(_ lm: NSLayoutManager, _ character: Int) -> CGFloat {
        lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: character)).x
    }

    private func hidden(_ storage: NSTextStorage, _ index: Int) -> Bool {
        storage.attribute(.tvmvHidden, at: index, effectiveRange: nil) != nil
    }

    func testLoadedInlineImageReservesWidth() {
        let (storage, lm) = stack("A ![b](x.png) c", size: CGSize(width: 40, height: 20))
        defer { withExtendedLifetime(storage) {} }   // the layout manager holds its storage weakly
        for i in 3...12 { XCTAssertTrue(hidden(storage, i), "\(i)") }
        XCTAssertFalse(hidden(storage, 2))
        XCTAssertEqual(storage.attribute(.tvmvImageCarrier, at: 2, effectiveRange: nil) as? String, "x.png")
        let space = (" " as NSString).size(withAttributes: [.font: theme.body]).width
        XCTAssertEqual(x(lm, 14) - x(lm, 2), 40 + space, accuracy: 0.5)
    }

    func testUnloadedInlineImageShowsAlt() {
        let (storage, _) = stack("A ![b](x.png) c")
        XCTAssertFalse(hidden(storage, 4))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? PlatformColor, theme.muted)
        for i in [2, 3] + Array(5...12) { XCTAssertTrue(hidden(storage, i), "\(i)") }
        XCTAssertNil(storage.attribute(.tvmvImageCarrier, at: 2, effectiveRange: nil))
    }

    func testEmptyAltShowsFileName() {
        let text = "Look ![](img/x.png) here"
        let (storage, _) = stack(text)
        let name = (text as NSString).range(of: "x.png")
        for i in name.location..<NSMaxRange(name) { XCTAssertFalse(hidden(storage, i), "\(i)") }
        let open = (text as NSString).range(of: "![](img/")
        for i in open.location..<NSMaxRange(open) { XCTAssertTrue(hidden(storage, i), "\(i)") }
        XCTAssertTrue(hidden(storage, NSMaxRange(name)))   // ")"
    }

    func testHugeInlineImageIsCapped() {
        let huge = InlineImageMetrics.size(natural: CGSize(width: 4000, height: 1000), theme: theme, column: 600)
        XCTAssertEqual(huge.height, 22.4, accuracy: 0.001)
        XCTAssertEqual(huge.width, 89.6, accuracy: 0.001)
        XCTAssertEqual(InlineImageMetrics.size(natural: CGSize(width: 30, height: 10), theme: theme, column: 600),
                       CGSize(width: 30, height: 10))
        let wide = InlineImageMetrics.size(natural: CGSize(width: 2000, height: 20), theme: theme, column: 600)
        XCTAssertEqual(wide.width, 600, accuracy: 0.001)
        XCTAssertEqual(wide.height, 6, accuracy: 0.001)
    }

    func testCellTreatsBlockImageAsInline() {
        let (storage, _) = stack("![b](x.png)", size: CGSize(width: 40, height: 20), blockImagesInline: true)
        XCTAssertEqual(storage.attribute(.tvmvImageCarrier, at: 0, effectiveRange: nil) as? String, "x.png")
        for i in 0..<storage.length {
            let p = storage.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertLessThanOrEqual(p?.minimumLineHeight ?? 0, theme.body.pointSize * 1.7, "\(i)")
        }
    }
}
