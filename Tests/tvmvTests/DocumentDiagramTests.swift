import XCTest
import AppKit
import TVMVCore
@testable import tvmv
@testable import TVMVNativeText

/// Mermaid blocks and display math show as their rendered picture.
@MainActor
final class DocumentDiagramTests: XCTestCase {
    private var window: NSWindow!
    private var view: DocumentTextView!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        view = DocumentTextView.make()
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = view
        window.contentView!.addSubview(scroll)
        // Each test renders afresh.
        view.diagramRenderer = DiagramRenderer()
    }

    private func pump(seconds: TimeInterval = 15, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private var ns: NSString { view.string as NSString }

    private func glyphHidden(_ index: Int) -> Bool {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        return lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: index)).contains(.null)
    }

    /// The height reserved for a diagram: on the line at its first line's newline.
    private func reservedHeight(_ diagram: MarkdownLayout.Diagram) -> CGFloat {
        let lm = view.layoutManager!
        lm.ensureLayout(for: view.textContainer!)
        let newline = NSMaxRange(ns.lineRange(for: NSRange(location: diagram.range.location, length: 0))) - 1
        return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: newline), effectiveRange: nil).height
    }

    private func settled(_ diagram: MarkdownLayout.Diagram) -> Bool {
        switch view.diagramRenderer.state(for: .init(diagram, theme: view.theme)) {
        case .rendered: view.diagramImage(for: diagram) != nil
        case .failed: true
        default: false
        }
    }

    func testAMermaidBlockShowsAsItsDiagram() {
        view.load("Intro.\n\n```mermaid\ngraph TD\n  A[Start] --> B[End]\n```\n\nAfter.\n")
        let diagram = view.layout.diagrams[0]
        XCTAssertFalse(glyphHidden(ns.range(of: "graph").location), "the source shows while it renders")
        pump { settled(diagram) }
        let (picture, size) = try! XCTUnwrap(view.diagramImage(for: diagram))
        XCTAssertGreaterThan(picture.size.height, 50)
        XCTAssertTrue(glyphHidden(ns.range(of: "graph").location))
        XCTAssertTrue(glyphHidden(ns.range(of: "B[End]").location))
        XCTAssertEqual(reservedHeight(diagram), size.height + view.theme.body.pointSize, accuracy: 1,
                       "the picture's height plus a half-em margin above and below")
        XCTAssertFalse(glyphHidden(ns.range(of: "After").location))
    }

    func testDisplayMathShowsAsItsFormula() {
        view.load("Before.\n\n$$\n\\int_0^1 x^2\\,dx = \\frac{1}{3}\n$$\n\nAfter.\n")
        let diagram = view.layout.diagrams[0]
        pump { settled(diagram) }
        let size = try! XCTUnwrap(view.diagramImage(for: diagram)).size
        XCTAssertGreaterThan(size.width, 50)
        XCTAssertTrue(glyphHidden(ns.range(of: "int_0").location))
        XCTAssertEqual(reservedHeight(diagram), size.height + view.theme.body.pointSize, accuracy: 1)
    }

    func testABrokenDiagramStaysSource() {
        view.load("```mermaid\ngraph TD\n  A -->\n```\n\n$$\\frac{$$\n")
        let diagrams = view.layout.diagrams
        XCTAssertEqual(diagrams.count, 2)
        pump { diagrams.allSatisfy(settled) }
        for diagram in diagrams {
            guard case .failed = view.diagramRenderer.state(for: .init(diagram, theme: view.theme)) else {
                return XCTFail("\(diagram.kind) should fail")
            }
            XCTAssertNil(view.diagramImage(for: diagram))
        }
        XCTAssertFalse(glyphHidden(ns.range(of: "graph").location))
        XCTAssertFalse(glyphHidden(ns.range(of: "frac").location))
    }

    func testRevealShowsTheSource() {
        view.load("```mermaid\ngraph TD\n  A --> B\n```\n\nAfter.\n")
        view.isEditable = true
        let diagram = view.layout.diagrams[0]
        pump { settled(diagram) }
        XCTAssertTrue(glyphHidden(ns.range(of: "graph").location))
        // A double-click on the picture (a click can't place the caret in hidden source).
        let lm = view.layoutManager!
        let after = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: ns.range(of: "After").location),
                                        effectiveRange: nil)
        XCTAssertFalse(view.revealDiagram(at: NSPoint(x: 450, y: after.minY + view.textContainerOrigin.y + 2)),
                       "only the picture reveals it")
        let lineAbove = after.minY + view.textContainerOrigin.y - view.theme.body.pointSize * 2
        XCTAssertTrue(view.revealDiagram(at: NSPoint(x: 450, y: lineAbove)))
        XCTAssertFalse(glyphHidden(ns.range(of: "graph").location))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: ns.range(of: "After").location, length: 0))
        XCTAssertTrue(glyphHidden(ns.range(of: "graph").location), "leaving the block shows the diagram again")
    }

    func testEditingTheSourceRendersTheNewDiagram() {
        view.load("```mermaid\ngraph TD\n  A --> B\n```\n")
        view.isEditable = true
        pump { settled(view.layout.diagrams[0]) }
        let at = ns.range(of: "B\n").location
        view.setSelectedRange(NSRange(location: at, length: 1))
        view.insertText("C", replacementRange: view.selectedRange())
        view.engine.ensureCurrentLayout()
        let edited = view.layout.diagrams[0]
        XCTAssertEqual(edited.source, "graph TD\n  A --> C")
        pump { settled(edited) }
        XCTAssertNotNil(view.diagramImage(for: edited))
    }

    func testEachDiagramRendersOnce() {
        let renderer = view.diagramRenderer
        view.load("```mermaid\ngraph TD\n  A --> B\n```\n\n```mermaid\ngraph TD\n  A --> B\n```\n")
        pump { view.layout.diagrams.allSatisfy(settled) }
        view.restyle(NSRange(location: 0, length: ns.length))
        XCTAssertEqual(renderer.rendersStarted, 1, "the same source in the same theme renders once")
        view.theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16, measure: 70,
                                 fullWidth: false, dark: true)
        pump { view.layout.diagrams.allSatisfy(settled) }
        XCTAssertEqual(renderer.rendersStarted, 2, "a new theme renders it again, in its colors")
    }
}
