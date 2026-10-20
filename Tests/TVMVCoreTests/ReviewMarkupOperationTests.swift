import XCTest
@testable import TVMVCore

/// Golden before → operation → after cases for every `ReviewMarkup` operation
/// and anchor kind. Each case asserts the exact text, that the patches are
/// coherent for `TextPatcher.apply`, and that the result parses with no
/// problems.
final class ReviewMarkupOperationTests: XCTestCase {

    typealias Review = ReviewMarkup.Review
    typealias Operation = @Sendable (Review) -> [TextPatcher.Patch]

    /// 2026-10-14 12:00 UTC.
    static let date = Date(timeIntervalSince1970: 1_791_979_200)
    static let utc = TimeZone(identifier: "UTC")!

    /// UTF-16 range of the first occurrence of `needle` in `text`.
    static func range(_ needle: String, in text: String) -> Range<Int> {
        let found = (text as NSString).range(of: needle)
        precondition(found.location != NSNotFound, "\(needle) not in \(text)")
        return found.location..<(found.location + found.length)
    }

    /// The empty range just after the first `needle`.
    static func after(_ needle: String, in text: String) -> Range<Int> {
        let end = range(needle, in: text).upperBound
        return end..<end
    }

    static func comment(on needle: String, _ body: String = "Why?") -> Operation {
        { review in
            review.addComment(range: range(needle, in: review.text), body: body, author: "ulf",
                              date: date, timeZone: utc, id: "rv-new1")
        }
    }

    static func point(after needle: String, _ body: String = "Source?") -> Operation {
        { review in
            review.addComment(range: after(needle, in: review.text), body: body, author: "@ulf",
                              date: date, timeZone: utc, id: "rv-new1")
        }
    }

    static func suggest(_ target: Range<Int>?, _ needle: String, _ replacement: String,
                        _ body: String = "Clearer.") -> Operation {
        { review in
            review.addSuggestion(range: target ?? range(needle, in: review.text),
                                 replacement: replacement, body: body, author: "ulf",
                                 date: date, timeZone: utc, id: "rv-new1")
        }
    }

    static func insert(after needle: String, _ replacement: String, _ body: String = "Clearer.") -> Operation {
        { review in
            review.addSuggestion(range: after(needle, in: review.text), replacement: replacement,
                                 body: body, author: "ulf", date: date, timeZone: utc, id: "rv-new1")
        }
    }

    static func reply(_ id: String, _ body: String) -> Operation {
        { $0.reply(id: id, body: body, author: "ulf", date: date, timeZone: utc) }
    }

    struct Case: Sendable {
        let name: String
        let before: String
        let operation: Operation
        let after: String
    }

    static let spec = ReviewMarkupParseTests.specExample

    static let cases: [Case] = [
        // MARK: addComment
        Case(name: "comment on a range, first thread",
             before: "The cache is stale.\n",
             operation: comment(on: "cache"),
             after: "The {==cache==}[^rv-new1] is stale.\n\n[^rv-new1]: @ulf 2026-10-14: Why?\n"),
        Case(name: "point comment",
             before: "The cache is stale.\n",
             operation: point(after: "stale."),
             after: "The cache is stale.[^rv-new1]\n\n[^rv-new1]: @ulf 2026-10-14: Source?\n"),
        Case(name: "comment appends after existing threads without a blank line",
             before: "A {==x==}[^rv-aaaa] b.\n\n[^rv-aaaa]: @bob 2026-10-13: Hm.\n",
             operation: comment(on: "b"),
             after: "A {==x==}[^rv-aaaa] {==b==}[^rv-new1].\n\n[^rv-aaaa]: @bob 2026-10-13: Hm.\n"
                + "[^rv-new1]: @ulf 2026-10-14: Why?\n"),
        Case(name: "comment on a file with no final newline",
             before: "Hello",
             operation: comment(on: "Hello"),
             after: "{==Hello==}[^rv-new1]\n\n[^rv-new1]: @ulf 2026-10-14: Why?\n"),
        Case(name: "comment after other trailing footnotes still gets a blank line",
             before: "Text[^1].\n\n[^1]: Plain footnote.\n",
             operation: comment(on: "Text"),
             after: "{==Text==}[^rv-new1][^1].\n\n[^1]: Plain footnote.\n\n"
                + "[^rv-new1]: @ulf 2026-10-14: Why?\n"),
        Case(name: "comment inside a code block becomes a point comment after it",
             before: "```swift\nlet x = 1\n```\nAfter.\n",
             operation: comment(on: "let x"),
             after: "```swift\nlet x = 1\n```\n[^rv-new1]\nAfter.\n\n[^rv-new1]: @ulf 2026-10-14: Why?\n"),
        Case(name: "comment inside a math block becomes a point comment after it",
             before: "$$\nx^2\n$$\n",
             operation: comment(on: "x^2"),
             after: "$$\nx^2\n$$\n[^rv-new1]\n\n[^rv-new1]: @ulf 2026-10-14: Why?\n"),
        Case(name: "comment in a table cell",
             before: "| a | b |\n|---|---|\n| one | two |\n",
             operation: comment(on: "one"),
             after: "| a | b |\n|---|---|\n| {==one==}[^rv-new1] | two |\n\n"
                + "[^rv-new1]: @ulf 2026-10-14: Why?\n"),
        Case(name: "multi-line comment body indents continuation lines",
             before: "Text.\n",
             operation: comment(on: "Text", "Line one\n\nLine two  "),
             after: "{==Text==}[^rv-new1].\n\n[^rv-new1]: @ulf 2026-10-14: Line one\n    Line two\n"),

        // MARK: addSuggestion
        Case(name: "suggest a substitution",
             before: "It is rebuilt lazily.\n",
             operation: suggest(nil, "lazily", "eagerly"),
             after: "It is rebuilt {~~lazily~>eagerly~~}[^rv-new1].\n\n"
                + "[^rv-new1]: @ulf 2026-10-14 suggestion: Clearer.\n"),
        Case(name: "suggest an insertion",
             before: "It is rebuilt.\n",
             operation: insert(after: "rebuilt", " eagerly"),
             after: "It is rebuilt{++ eagerly++}[^rv-new1].\n\n"
                + "[^rv-new1]: @ulf 2026-10-14 suggestion: Clearer.\n"),
        Case(name: "suggest a deletion with no body",
             before: "It is really rebuilt.\n",
             operation: suggest(nil, "really ", "", ""),
             after: "It is {--really --}[^rv-new1]rebuilt.\n\n"
                + "[^rv-new1]: @ulf 2026-10-14 suggestion:\n"),

        // MARK: reply
        Case(name: "reply appends an indented entry",
             before: "x[^rv-aaaa]\n\n[^rv-aaaa]: @bob 2026-10-13: Q?\n",
             operation: reply("rv-aaaa", "A."),
             after: "x[^rv-aaaa]\n\n[^rv-aaaa]: @bob 2026-10-13: Q?\n    @ulf 2026-10-14: A.\n"),
        Case(name: "reply lands after earlier replies, before the next thread",
             before: "x[^rv-aaaa] y[^rv-bbbb]\n\n[^rv-aaaa]: @bob 2026-10-13: Q?\n"
                + "    @ann 2026-10-13: Hm.\n[^rv-bbbb]: @bob 2026-10-13: Other.\n",
             operation: reply("rv-aaaa", "A.\nMore."),
             after: "x[^rv-aaaa] y[^rv-bbbb]\n\n[^rv-aaaa]: @bob 2026-10-13: Q?\n"
                + "    @ann 2026-10-13: Hm.\n    @ulf 2026-10-14: A.\n    More.\n"
                + "[^rv-bbbb]: @bob 2026-10-13: Other.\n"),
        Case(name: "reply to a thread with no final newline",
             before: "x[^rv-aaaa]\n\n[^rv-aaaa]: @bob 2026-10-13: Q?",
             operation: reply("rv-aaaa", "A."),
             after: "x[^rv-aaaa]\n\n[^rv-aaaa]: @bob 2026-10-13: Q?\n    @ulf 2026-10-14: A."),

        // MARK: resolve
        Case(name: "resolve a highlight keeps the text and drops the blank line",
             before: "The {==cache==}[^rv-aaaa] is stale.\n\n[^rv-aaaa]: @bob 2026-10-13: Why?\n"
                + "    @ulf 2026-10-14: Because.\n",
             operation: { $0.resolve(id: "rv-aaaa") },
             after: "The cache is stale.\n"),
        Case(name: "resolve a point comment",
             before: "Stale.[^rv-aaaa] Fresh.\n\n[^rv-aaaa]: @bob 2026-10-13: Source?\n",
             operation: { $0.resolve(id: "rv-aaaa") },
             after: "Stale. Fresh.\n"),
        Case(name: "resolve a point comment after a code block removes its line",
             before: "```\ncode\n```\n[^rv-aaaa]\nAfter.\n\n[^rv-aaaa]: @bob 2026-10-13: Hm.\n",
             operation: { $0.resolve(id: "rv-aaaa") },
             after: "```\ncode\n```\nAfter.\n"),
        Case(name: "resolve the middle thread leaves its neighbours",
             before: "a[^rv-aaaa] b[^rv-bbbb] c[^rv-cccc]\n\n[^rv-aaaa]: @x 2026-10-13: 1\n"
                + "[^rv-bbbb]: @x 2026-10-13: 2\n    @y 2026-10-13: 2b\n[^rv-cccc]: @x 2026-10-13: 3\n",
             operation: { $0.resolve(id: "rv-bbbb") },
             after: "a[^rv-aaaa] b c[^rv-cccc]\n\n[^rv-aaaa]: @x 2026-10-13: 1\n"
                + "[^rv-cccc]: @x 2026-10-13: 3\n"),
        Case(name: "resolve the first thread keeps the blank line for the rest",
             before: "a[^rv-aaaa] b[^rv-bbbb]\n\n[^rv-aaaa]: @x 2026-10-13: 1\n[^rv-bbbb]: @x 2026-10-13: 2\n",
             operation: { $0.resolve(id: "rv-aaaa") },
             after: "a b[^rv-bbbb]\n\n[^rv-bbbb]: @x 2026-10-13: 2\n"),
        Case(name: "resolve a thread with highlight and point anchors",
             before: "{==a==}[^rv-aaaa] b[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-13: 1\n",
             operation: { $0.resolve(id: "rv-aaaa") },
             after: "a b\n"),
        Case(name: "resolve does not settle a suggestion",
             before: "{++a++}[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: 1\n",
             operation: { $0.resolve(id: "rv-aaaa") },
             after: "{++a++}[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: 1\n"),
        Case(name: "resolve an orphan thread deletes it",
             before: "Text.\n\n[^rv-aaaa]: @x 2026-10-13: lost\n",
             operation: { $0.resolve(id: "rv-aaaa") },
             after: "Text.\n"),
        Case(name: "resolve a dangling anchor removes its markup",
             before: "The {==cache==}[^rv-aaaa] is stale.\n",
             operation: { $0.resolve(id: "rv-aaaa") },
             after: "The cache is stale.\n"),

        // MARK: accept / reject
        Case(name: "accept an insertion",
             before: "It is rebuilt{++ eagerly++}[^rv-aaaa].\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n",
             operation: { $0.accept(id: "rv-aaaa") },
             after: "It is rebuilt eagerly.\n"),
        Case(name: "reject an insertion",
             before: "It is rebuilt{++ eagerly++}[^rv-aaaa].\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n",
             operation: { $0.reject(id: "rv-aaaa") },
             after: "It is rebuilt.\n"),
        Case(name: "accept a deletion",
             before: "It is {--really --}[^rv-aaaa]rebuilt.\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n",
             operation: { $0.accept(id: "rv-aaaa") },
             after: "It is rebuilt.\n"),
        Case(name: "reject a deletion",
             before: "It is {--really --}[^rv-aaaa]rebuilt.\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n",
             operation: { $0.reject(id: "rv-aaaa") },
             after: "It is really rebuilt.\n"),
        Case(name: "accept a substitution",
             before: "It is {~~lazy~>eager~~}[^rv-aaaa].\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n",
             operation: { $0.accept(id: "rv-aaaa") },
             after: "It is eager.\n"),
        Case(name: "reject a substitution",
             before: "It is {~~lazy~>eager~~}[^rv-aaaa].\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n",
             operation: { $0.reject(id: "rv-aaaa") },
             after: "It is lazy.\n"),
        Case(name: "accept a comment resolves it",
             before: "{==a==}[^rv-aaaa] b[^rv-bbbb]\n\n[^rv-aaaa]: @x 2026-10-13: 1\n[^rv-bbbb]: @x 2026-10-13: 2\n",
             operation: { $0.accept(id: "rv-aaaa") },
             after: "a b[^rv-bbbb]\n\n[^rv-bbbb]: @x 2026-10-13: 2\n"),
        Case(name: "reject a point comment resolves it",
             before: "b[^rv-bbbb]\n\n[^rv-bbbb]: @x 2026-10-13: 2\n",
             operation: { $0.reject(id: "rv-bbbb") },
             after: "b\n"),
        Case(name: "accept a multi-anchor id settles every anchor (spec example)",
             before: spec,
             operation: { $0.accept(id: "rv-p2x7") },
             after: """
                The {==cache is invalidated on every save==}[^rv-k3f9] and the index is
                rebuilt eagerly on open from disk.
                Autosave writes are exempt. A point comment.[^rv-z9y8]

                [^rv-k3f9]: @ulf 2026-10-14: True for autosave too?
                    @claude 2026-10-14: No, see the added sentence.
                [^rv-z9y8]: @ulf 2026-10-14: Needs a source.

                """),
        Case(name: "reject a multi-anchor id settles every anchor (spec example)",
             before: spec,
             operation: { $0.reject(id: "rv-p2x7") },
             after: """
                The {==cache is invalidated on every save==}[^rv-k3f9] and the index is
                rebuilt lazily from disk.
                 A point comment.[^rv-z9y8]

                [^rv-k3f9]: @ulf 2026-10-14: True for autosave too?
                    @claude 2026-10-14: No, see the added sentence.
                [^rv-z9y8]: @ulf 2026-10-14: Needs a source.

                """),
        Case(name: "accept a multi-block suggestion",
             before: "{--Old paragraph.--}[^rv-aaaa]\n\n{++New paragraph.++}[^rv-aaaa]\n\n"
                + "Kept.\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: Rewrite.\n",
             operation: { $0.accept(id: "rv-aaaa") },
             after: "\n\nNew paragraph.\n\nKept.\n"),
        Case(name: "reject a multi-block suggestion",
             before: "{--Old paragraph.--}[^rv-aaaa]\n\n{++New paragraph.++}[^rv-aaaa]\n\n"
                + "Kept.\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: Rewrite.\n",
             operation: { $0.reject(id: "rv-aaaa") },
             after: "Old paragraph.\n\n\n\nKept.\n"),
        Case(name: "accept a suggestion in a table cell",
             before: "| a |\n|---|\n| {~~one~>uno~~}[^rv-aaaa] |\n\n[^rv-aaaa]: @x 2026-10-13 suggestion: y\n",
             operation: { $0.accept(id: "rv-aaaa") },
             after: "| a |\n|---|\n| uno |\n"),

        // MARK: acceptAll / rejectAll
        Case(name: "accept all settles suggestions and keeps comments (spec example)",
             before: spec,
             operation: { $0.acceptAll() },
             after: """
                The {==cache is invalidated on every save==}[^rv-k3f9] and the index is
                rebuilt eagerly on open from disk.
                Autosave writes are exempt. A point comment.[^rv-z9y8]

                [^rv-k3f9]: @ulf 2026-10-14: True for autosave too?
                    @claude 2026-10-14: No, see the added sentence.
                [^rv-z9y8]: @ulf 2026-10-14: Needs a source.

                """),
        Case(name: "reject all with several suggestion threads",
             before: "A {++b++}[^rv-aaaa] c {--d--}[^rv-bbbb] {~~e~>f~~}[^rv-cccc].\n\n"
                + "[^rv-aaaa]: @x 2026-10-13 suggestion: 1\n[^rv-bbbb]: @x 2026-10-13 suggestion: 2\n"
                + "[^rv-cccc]: @x 2026-10-13 suggestion: 3\n",
             operation: { $0.rejectAll() },
             after: "A  c d e.\n"),
        Case(name: "accept all with several suggestion threads separated by blank lines",
             before: "A {++b++}[^rv-aaaa] c {--d--}[^rv-bbbb].\n\n"
                + "[^rv-aaaa]: @x 2026-10-13 suggestion: 1\n\n[^rv-bbbb]: @x 2026-10-13 suggestion: 2\n",
             operation: { $0.acceptAll() },
             after: "A b c .\n"),
    ]

    func testGoldenCases() {
        for c in Self.cases {
            let review = ReviewMarkup.parse(c.before)
            let patches = c.operation(review)
            assertCoherent(patches, c.name)
            guard let result = TextPatcher.apply(patches, to: c.before) else {
                XCTFail("\(c.name): patches do not apply: \(patches)")
                continue
            }
            XCTAssertEqual(result, c.after, c.name)
            XCTAssertEqual(ReviewMarkup.parse(result).problems, [], "\(c.name): result has problems")
        }
    }

    // MARK: Refusals
    //
    // An operation that would produce broken markup returns no patches.

    func testRefusals() {
        let text = """
            The {==cache==}[^rv-aaaa] is `stale code` here.

            Second paragraph.

            [^rv-aaaa]: @x 2026-10-13: 1

            """
        let review = ReviewMarkup.parse(text)
        func comment(_ range: Range<Int>) -> [TextPatcher.Patch] {
            review.addComment(range: range, body: "b", author: "ulf",
                              date: Self.date, timeZone: Self.utc, id: "rv-new1")
        }
        let r = { Self.range($0, in: text) }
        XCTAssertEqual(comment(r("here.\n\nSecond")), [], "spans a blank line")
        XCTAssertEqual(comment(r("che==}[^rv-aaaa] is")), [], "overlaps an anchor")
        XCTAssertEqual(comment(r("[^rv-aaaa]")), [], "covers a ref")
        XCTAssertEqual(comment(r("stale")), [], "inside a code span")
        XCTAssertEqual(comment(r("@x")), [], "inside a thread definition")
        XCTAssertEqual(comment(0..<(text.utf16.count + 1)), [], "out of bounds")
        XCTAssertEqual(comment(r("{==ca").lowerBound + 2..<(r("{==ca").lowerBound + 2)), [],
                       "point inside an anchor")
        XCTAssertEqual(review.addSuggestion(range: r("Second"), replacement: "x~~}y", body: "",
                                            author: "ulf", date: Self.date, timeZone: Self.utc,
                                            id: "rv-new1"), [], "replacement breaks the markup")
        XCTAssertEqual(review.addSuggestion(range: r("Second"), replacement: "a\n\nb", body: "",
                                            author: "ulf", date: Self.date, timeZone: Self.utc,
                                            id: "rv-new1"), [], "replacement adds a block")
        XCTAssertEqual(review.addSuggestion(range: 5..<5, replacement: "", body: "",
                                            author: "ulf", date: Self.date, timeZone: Self.utc,
                                            id: "rv-new1"), [], "no change at all")
        XCTAssertEqual(comment(r("Second")).isEmpty, false, "control: a valid range works")
        XCTAssertEqual(review.addComment(range: r("Second"), body: "b", author: "ulf",
                                         date: Self.date, timeZone: Self.utc, id: "rv-aaaa"), [],
                       "id already in use")
        XCTAssertEqual(review.reply(id: "rv-zzzz", body: "b", author: "ulf",
                                    date: Self.date, timeZone: Self.utc), [], "no such thread")

        let code = "```\nlet x\n```\n"
        XCTAssertEqual(ReviewMarkup.parse(code).addSuggestion(
            range: Self.range("let", in: code), replacement: "var", body: "", author: "ulf",
            date: Self.date, timeZone: Self.utc, id: "rv-new1"), [], "suggestion inside code")
    }

    func testAddCommentGeneratesAFreshIDWhenNoneIsGiven() {
        let text = "a[^rv-aaaa]\n\n[^rv-aaaa]: @x 2026-10-13: 1\n"
        let review = ReviewMarkup.parse(text)
        let patches = review.addComment(range: 0..<1, body: "b", author: "ulf",
                                        date: Self.date, timeZone: Self.utc)
        let result = TextPatcher.apply(patches, to: text)!
        let after = ReviewMarkup.parse(result)
        XCTAssertEqual(after.problems, [])
        XCTAssertEqual(after.threads.count, 2)
        XCTAssertNotEqual(after.threads[1].id, "rv-aaaa")
    }

    func testDateUsesTheGivenTimeZone() {
        // 2026-10-14 23:30 UTC is already the 15th in Copenhagen.
        let late = Date(timeIntervalSince1970: 1_792_020_600)
        let patches = ReviewMarkup.parse("a\n").addComment(
            range: 0..<1, body: "b", author: "ulf", date: late,
            timeZone: TimeZone(identifier: "Europe/Copenhagen")!, id: "rv-new1")
        XCTAssertEqual(TextPatcher.apply(patches, to: "a\n"),
                       "{==a==}[^rv-new1]\n\n[^rv-new1]: @ulf 2026-10-15: b\n")
    }

    // MARK: newID

    func testNewIDShapeAndAvoidsExisting() {
        var rng = SplitMix64(seed: 7)
        let first = ReviewMarkup.newID(existing: [], using: &rng)
        XCTAssertNotNil(first.range(of: "^rv-[a-z0-9]{4}$", options: .regularExpression), first)

        var replay = SplitMix64(seed: 7)
        let second = ReviewMarkup.newID(existing: [first], using: &replay)
        XCTAssertNotEqual(second, first)
        XCTAssertNotNil(second.range(of: "^rv-[a-z0-9]{4}$", options: .regularExpression), second)

        let system = ReviewMarkup.newID(existing: [])
        XCTAssertNotNil(system.range(of: "^rv-[a-z0-9]{4}$", options: .regularExpression), system)
    }

    // MARK: Helpers

    func assertCoherent(_ patches: [TextPatcher.Patch], _ name: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        var previous = 0
        for patch in patches {
            XCTAssertTrue(patch.from >= previous && patch.to >= patch.from,
                          "\(name): patches not ascending/non-overlapping: \(patches)",
                          file: file, line: line)
            previous = patch.to
        }
    }
}
