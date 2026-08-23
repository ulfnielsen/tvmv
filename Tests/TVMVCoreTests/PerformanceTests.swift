import XCTest
@testable import TVMVCore

/// Large-document performance gates for the native pipeline.
///
/// Fixtures are generated deterministically (no megabyte files in the repo).
/// The `measure` gates run only with `TVMV_PERF=1` in the environment:
///
///     env TVMV_PERF=1 DEVELOPER_DIR=... swift test --filter PerformanceTests
///
/// WebKit-side costs (IPC, innerHTML, enrichment) are outside swift test's
/// reach — measure those in Instruments (see review.md for the recipe).
final class PerformanceTests: XCTestCase {

    /// Deterministic markdown of roughly `megabytes` MB exercising the parser
    /// broadly: headings, prose, lists, tables, fenced code.
    static func fixture(megabytes: Int) -> String {
        let section = """
        ## Section marker

        A paragraph of steady prose with **emphasis**, `inline code`, and a
        [link](https://example.invalid/path) so inline parsing has real work.

        - list item one with a bit of text
        - list item two with a bit more text
        - [ ] an unchecked task

        | Column A | Column B |
        |----------|----------|
        | value    | value    |

        ```swift
        func example(_ n: Int) -> Int {
            return (0..<n).reduce(0, +)
        }
        ```

        """
        let target = megabytes * 1_000_000
        var out = "# Fixture document\n\n"
        out.reserveCapacity(target + section.count)
        while out.utf8.count < target {
            out += section
        }
        return out
    }

    private var perfEnabled: Bool {
        ProcessInfo.processInfo.environment["TVMV_PERF"] == "1"
    }

    func testFixtureGeneratorProducesParseableDocument() {
        // Always-on smoke: the generator itself and one small end-to-end parse.
        let doc = Self.fixture(megabytes: 1)
        XCTAssertGreaterThan(doc.utf8.count, 900_000)
        let html = renderHTML(String(doc.prefix(10_000)), sourcePos: true)
        XCTAssertTrue(html.contains("<h1"))
        XCTAssertTrue(html.contains("data-sourcepos"))
    }

    func testRenderPerformance1MB() throws {
        try XCTSkipUnless(perfEnabled, "set TVMV_PERF=1 to run performance gates")
        let doc = Self.fixture(megabytes: 1)
        measure { _ = renderHTML(doc, sourcePos: true) }
    }

    func testRenderPerformance10MB() throws {
        try XCTSkipUnless(perfEnabled, "set TVMV_PERF=1 to run performance gates")
        let doc = Self.fixture(megabytes: 10)
        measure { _ = renderHTML(doc, sourcePos: true) }
    }

    func testHTMLEncodingPerformance1MB() throws {
        try XCTSkipUnless(perfEnabled, "set TVMV_PERF=1 to run performance gates")
        let html = renderHTML(Self.fixture(megabytes: 1), sourcePos: true)
        measure { _ = JSString.literal(html) }
    }

    func testPatchApplyPerformanceOnLargeDocument() throws {
        try XCTSkipUnless(perfEnabled, "set TVMV_PERF=1 to run performance gates")
        let doc = Self.fixture(megabytes: 10)
        let mid = doc.utf16.count / 2
        let patches = [TextPatcher.Patch(from: mid, to: mid, insert: "typed text")]
        measure {
            _ = TextPatcher.apply(patches, to: doc,
                                  expectedUTF16Length: doc.utf16.count + 10)
        }
    }

    func testThumbnailBoundedReadOnLargeFile() throws {
        // Always-on: the thumbnail path must stay O(bounded) however large the
        // file is. 20 MB in, bounded lines out, quickly.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.md")
        try Self.fixture(megabytes: 20).data(using: .utf8)!.write(to: url)

        let start = Date()
        let decoded = MarkdownText.decode(
            try FileHandle(forReadingFrom: url).read(upToCount: 512 * 1024) ?? Data()).text
        XCTAssertLessThanOrEqual(decoded.utf8.count, 512 * 1024)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }
}
