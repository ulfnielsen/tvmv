import XCTest
@testable import TVMVCore

/// Golden layout tests: the Swift half of the gate that holds the Linux port
/// of `MarkdownLayoutParser` (`linux/src/layout.rs`) to this one.
///
/// Every fixture's layout is described as JSON and compared against
/// `Fixtures/layout/<name>.json`. The Rust suite (`linux/tests/layout_golden.rs`)
/// asserts the same files with the same description; keep `describe` in step
/// with its `describe`. The expectations were generated on Linux. This parser
/// is the reference, so where the two disagree, the Rust port is what gets
/// fixed. See `Fixtures/layout/README.md`.
final class GoldenLayoutTests: XCTestCase {

    private static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TVMVCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // <repo root>
        .appendingPathComponent("Fixtures")

    /// Every Markdown fixture: the showcase, the HTML corpus, and the layout corpus.
    private func cases() throws -> [(name: String, url: URL)] {
        var cases = [(name: "showcase", url: Self.fixturesURL.appendingPathComponent("showcase.md"))]
        for dir in ["golden", "layout"] {
            let entries = try FileManager.default.contentsOfDirectory(
                at: Self.fixturesURL.appendingPathComponent(dir), includingPropertiesForKeys: nil)
            for url in entries where url.pathExtension == "md" {
                let name = url.deletingPathExtension().lastPathComponent
                if name != "README" { cases.append((name: name, url: url)) }
            }
        }
        return cases.sorted { $0.name < $1.name }
    }

    private static func r(_ range: NSRange) -> String { "\(range.location)+\(range.length)" }

    private static func describe(_ style: MarkdownLayout.Style) -> String {
        switch style {
        case .emphasis: return "emphasis"
        case .strong: return "strong"
        case .strikethrough: return "strikethrough"
        case .code: return "code"
        case .link(let url): return "link(\(url))"
        case .autolink(let url): return "autolink(\(url))"
        case .heading(let level): return "heading(\(level))"
        case .codeBlock(let language): return "codeBlock(\(language ?? ""))"
        case .html: return "html"
        case .image: return "image"
        case .review(let role, let id): return "review(\(role),\(id))"
        }
    }

    /// The description both suites produce.
    static func describe(_ layout: MarkdownLayout) -> [String: Any] {
        [
            "length": layout.length,
            "styles": layout.styles.map { "\(r($0.range)) \(describe($0.style))" },
            "markers": layout.markers.map { "\(r($0.range)) \(r($0.unit))\($0.collapsesLine ? " line" : "")" },
            "spellExempt": layout.spellExempt.map { r($0) },
            "codeBlocks": layout.codeBlocks.map { "\(r($0.range)) \(r($0.body))" },
            "headings": layout.headings.map { "\($0.level) \(r($0.range)) \($0.title)" },
            "blocks": layout.blocks.map { "\(r($0.range)) \($0.kind)" },
            "softBreaks": layout.softBreaks.map { "\($0)" },
            "listItems": layout.listItems.map { item -> String in
                let task = item.task.map { $0 ? "done" : "todo" } ?? "-"
                let checkbox = item.checkbox.map { r($0) } ?? "-"
                return "\(r(item.marker)) \(r(item.bullet)) \(item.level) \(item.ordered ? "ordered" : "bullet") \(task) \(checkbox)"
            },
            "quoteLines": layout.quoteLines.map { "\(r($0.prefix)) \($0.level)" },
            "tables": layout.tables.map { table -> String in
                let alignments = table.alignments.map { "\($0)" }.joined(separator: ",")
                let rows = table.rows.map { $0.map { r($0) }.joined(separator: " ") }.joined(separator: " / ")
                return "\(r(table.range)) \(alignments) \(rows)"
            },
            "blockImages": layout.blockImages.map { "\(r($0.range)) \($0.url) \($0.alt)" },
            "definitions": layout.definitions.map { "\(r($0.range)) \($0.text)" },
        ]
    }

    func testLayoutsMatchTheCorpus() throws {
        let corpus = Self.fixturesURL.appendingPathComponent("layout")
        guard FileManager.default.fileExists(atPath: corpus.path) else {
            throw XCTSkip("Fixtures/layout is not in this working tree.")
        }
        for (name, url) in try cases() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let expectedURL = corpus.appendingPathComponent("\(name).json")
            let data = try Data(contentsOf: expectedURL)
            guard let expected = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("\(name).json is not a JSON object"); continue
            }
            let actual = Self.describe(MarkdownLayoutParser.parse(text))
            XCTAssertEqual(Set(actual.keys), Set(expected.keys), "\(name): keys")
            XCTAssertEqual(actual["length"] as? Int, expected["length"] as? Int, "\(name).length")
            for key in actual.keys.sorted() where key != "length" {
                let a = actual[key] as? [String] ?? []
                let e = expected[key] as? [String] ?? []
                guard a != e else { continue }
                let i = zip(a, e).firstIndex { $0 != $1 } ?? min(a.count, e.count)
                XCTFail("""
                    \(name).\(key): first difference at [\(i)]
                    expected: \(i < e.count ? e[i] : "<end>")
                    actual:   \(i < a.count ? a[i] : "<end>")
                    The Swift parser is the reference: fix linux/src/layout.rs, then regenerate there.
                    """)
            }
        }
    }
}
