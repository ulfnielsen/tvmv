import XCTest
@testable import TVMVCore

/// Expected values were produced by boot.js's own `makeSlugger` (node).
final class HeadingSluggerTests: XCTestCase {
    func testMatchesTheWebReadersSlugs() {
        var slugger = HeadingSlugger()
        let cases: [(String, String)] = [
            ("Hello World", "hello-world"),
            ("Hello World", "hello-world-1"),
            ("Hello World-1", "hello-world-1-1"),
            ("Hello World", "hello-world-2"),
            ("Ünïcödé Straße", "ünïcödé-straße"),
            ("C++ & Rust!", "c-rust"),
            ("  spaced  out  ", "-spaced-out-"),
            ("emoji 😀 here", "emoji-here"),
            ("日本語 見出し", "日本語-見出し"),
            ("a_b-c", "a_b-c"),
            ("Ⅻ roman ½", "ⅻ-roman-½"),
        ]
        for (title, expected) in cases {
            XCTAssertEqual(slugger.slug(title), expected, title)
        }
    }
}
