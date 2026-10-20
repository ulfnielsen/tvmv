import XCTest
@testable import TVMVCore

/// Round-trip properties of `ReviewMarkup` over every position in a small
/// corpus: creating a thread and then resolving or rejecting it restores the
/// bytes, accepting a suggestion equals making the edit directly, and every
/// operation's patches apply cleanly and re-parse with no problems.
final class ReviewMarkupPropertyTests: XCTestCase {

    static let date = ReviewMarkupOperationTests.date
    static let utc = ReviewMarkupOperationTests.utc

    static let corpus: [String] = [
        "The cache is stale.\n",
        "# Title\n\nFirst *para* with `code` and a [link](x).\n\n- one\n- two 👍\n",
        "```swift\nlet x = 1\n```\n",
        "Intro.\n\n```\ncode\n```\n\n$$\nx^2\n$$\nAfter.\n",
        "| a | b |\n|---|---|\n| one | two |\n",
        "> quoted line\n> second\n\nTail é.\n",
        "Text[^1].\n\n[^1]: Plain footnote.\n",
        ReviewMarkupParseTests.specExample,
        "A {++b++}[^rv-aaaa] c.\n\n{--Gone.--}[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n",
    ]

    /// Every offset that does not split a surrogate pair.
    private func offsets(_ text: String) -> [Int] {
        let units = Array(text.utf16)
        return (0...units.count).filter { $0 == units.count || !UTF16.isTrailSurrogate(units[$0]) }
    }

    private func ranges(_ text: String) -> [Range<Int>] {
        let valid = offsets(text)
        let set = Set(valid)
        return valid.flatMap { start in
            [0, 1, 2, 5, 11].map { start..<(start + $0) }.filter { set.contains($0.upperBound) }
        }
    }

    private func apply(_ patches: [TextPatcher.Patch], _ text: String,
                       file: StaticString = #filePath, line: UInt = #line) -> String? {
        let result = TextPatcher.apply(patches, to: text)
        XCTAssertNotNil(result, "patches do not apply to \(text.debugDescription): \(patches)",
                        file: file, line: line)
        return result
    }

    private func replacing(_ text: String, _ range: Range<Int>, with insert: String) -> String {
        TextPatcher.apply([.init(from: range.lowerBound, to: range.upperBound, insert: insert)],
                          to: text)!
    }

    func testCorpusParsesCleanly() {
        for text in Self.corpus {
            XCTAssertEqual(ReviewMarkup.parse(text).problems, [], text)
        }
    }

    /// addComment → resolve restores the original bytes.
    func testCommentThenResolveRestoresTheText() {
        var made = 0
        for text in Self.corpus {
            let review = ReviewMarkup.parse(text)
            for range in ranges(text) {
                let patches = review.addComment(range: range, body: "Note.\nMore.", author: "ulf",
                                                date: Self.date, timeZone: Self.utc, id: "rv-new1")
                guard !patches.isEmpty, let commented = apply(patches, text) else { continue }
                made += 1
                let after = ReviewMarkup.parse(commented)
                XCTAssertEqual(after.problems, [], "\(range) in \(text.debugDescription)")
                let restored = apply(after.resolve(id: "rv-new1"), commented)
                XCTAssertEqual(restored, text, "\(range) via \(commented.debugDescription)")
            }
        }
        XCTAssertGreaterThan(made, 500, "too few placements succeeded to mean anything")
    }

    /// addSuggestion → reject restores the bytes; → accept equals the direct edit.
    func testSuggestionRejectRestoresAndAcceptEqualsTheEdit() {
        var made = 0
        for text in Self.corpus {
            let review = ReviewMarkup.parse(text)
            for range in ranges(text) {
                for replacement in ["X", "", "new words"] {
                    let patches = review.addSuggestion(
                        range: range, replacement: replacement, body: "Why.", author: "ulf",
                        date: Self.date, timeZone: Self.utc, id: "rv-new1")
                    guard !patches.isEmpty, let suggested = apply(patches, text) else { continue }
                    made += 1
                    let after = ReviewMarkup.parse(suggested)
                    XCTAssertEqual(after.problems, [], "\(range) in \(text.debugDescription)")
                    XCTAssertEqual(apply(after.reject(id: "rv-new1"), suggested), text,
                                   "reject \(range) via \(suggested.debugDescription)")
                    XCTAssertEqual(apply(after.accept(id: "rv-new1"), suggested),
                                   replacing(text, range, with: replacement),
                                   "accept \(range) via \(suggested.debugDescription)")
                }
            }
        }
        XCTAssertGreaterThan(made, 1_000, "too few placements succeeded to mean anything")
    }

    /// reply adds exactly one entry and leaves the document problem-free.
    func testReplyAddsOneEntry() {
        for text in Self.corpus {
            let review = ReviewMarkup.parse(text)
            for thread in review.threads {
                let patches = review.reply(id: thread.id, body: "Agreed.", author: "ann",
                                           date: Self.date, timeZone: Self.utc)
                guard let result = apply(patches, text) else { continue }
                let after = ReviewMarkup.parse(result)
                XCTAssertEqual(after.problems, [])
                XCTAssertEqual(after.thread(id: thread.id)?.entries.last?.body, "Agreed.")
                XCTAssertEqual(after.thread(id: thread.id)?.entries.count, thread.entries.count + 1)
            }
        }
    }

    /// Every settle operation on every id applies cleanly, removes that id,
    /// and leaves no problems behind.
    func testEverySettleOperationAppliesCleanly() {
        for text in Self.corpus {
            let review = ReviewMarkup.parse(text)
            var operations: [(String, [TextPatcher.Patch])] = [
                ("acceptAll", review.acceptAll()), ("rejectAll", review.rejectAll()),
            ]
            for id in review.ids {
                operations += [("resolve \(id)", review.resolve(id: id)),
                               ("accept \(id)", review.accept(id: id)),
                               ("reject \(id)", review.reject(id: id))]
            }
            for (name, patches) in operations {
                guard let result = apply(patches, text) else { continue }
                let after = ReviewMarkup.parse(result)
                XCTAssertEqual(after.problems, [], "\(name) on \(text.debugDescription)")
                if name == "acceptAll" || name == "rejectAll" {
                    XCTAssertFalse(after.anchors.contains(where: \.kind.isSuggestion), name)
                } else if !patches.isEmpty {
                    XCTAssertFalse(after.ids.contains(String(name.split(separator: " ")[1])), name)
                }
            }
        }
    }

    /// Parsing is a pure function of the text, and every anchor's ranges
    /// slice back to well-formed syntax.
    func testParseIsStableAndRangesSliceToSyntax() {
        for text in Self.corpus {
            let review = ReviewMarkup.parse(text)
            XCTAssertEqual(review, ReviewMarkup.parse(text))
            let units = Array(text.utf16)
            func s(_ r: Range<Int>) -> String { String(decoding: units[r], as: UTF16.self) }
            for anchor in review.anchors {
                XCTAssertEqual(s(anchor.ref), "[^\(anchor.id)]")
                XCTAssertTrue(s(anchor.range).hasSuffix(s(anchor.ref)))
                let opener = ["highlight": "{==", "insertion": "{++", "deletion": "{--",
                              "substitution": "{~~", "point": "[^"][anchor.kind.rawValue]!
                XCTAssertTrue(s(anchor.range).hasPrefix(opener), s(anchor.range))
            }
        }
    }
}
