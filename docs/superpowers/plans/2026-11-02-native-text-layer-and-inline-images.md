# Shared TextKit 1 layer and inline images (macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the platform-neutral parts of the Mac native view into a new `TVMVNativeText` target that also compiles for iOS, with no Mac behavior change; then render inline images as pictures on macOS through that layer.

**Architecture:** `TVMVNativeText` sits between `TVMVCore` (pure) and the apps. It holds what only talks to TextKit 1: theme, styler, layout-manager delegate, image loading, decoration drawing and geometry, and the parse/reveal engine. `DocumentTextView` (AppKit) keeps events, menus, find, table grids and review cards, and calls into the layer. Inline images are a new `MarkdownLayout.inlineImages` list, styled with a clear carrier character that reserves the picture's width, drawn by the shared decorations.

**Tech Stack:** Swift 6, SwiftPM, AppKit/UIKit TextKit 1 (`NSLayoutManager`), cmark-gfm via `TVMVCore`, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-02-ios-native-editor-design.md` (build-order steps 1 and 2). Base: `docs/superpowers/specs/2026-10-14-native-editor-design.md`.

This is plan 1 of several. Later plans: the iOS view (spec step 3), reader features, lists/images on iOS, tables, review comments, cleanup.

## Global Constraints

- Platforms: `.macOS(.v14)`, `.iOS("26.0")` (Package.swift, unchanged).
- Swift 6 language mode, strict concurrency; UI types are `@MainActor`.
- `TVMVNativeText` imports Foundation, CoreGraphics, ImageIO and `TVMVCore`, plus AppKit or UIKit only under `#if os(macOS)` / `#if os(iOS)`. It must build for iOS Simulator at the end of every task.
- Tests run with the Xcode toolchain: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (the active toolchain is CLT).
- iOS compile gate: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme TVMVNativeText -destination 'generic/platform=iOS Simulator' build` → `** BUILD SUCCEEDED **`.
- Tasks 1–6 are behavior-neutral: the full existing suite (`Tests/tvmvTests`, `Tests/TVMVCoreTests`) passes unchanged after each, except for test call sites that only change the type a moved helper lives on.
- The Markdown text is never changed by display code; hidden ranges are only ever markup (spec anti-goal).
- Commit messages follow the repo's style: a plain sentence, prefixed with the area (e.g. `Native text: move the theme into TVMVNativeText`).

## Review Focus

1. **An image that never loads** (missing file, 404, refused by the caps): the alt text must stay readable in the muted style, never vanish with the hidden source. → Task 9, `testUnloadedInlineImageShowsAlt`.
2. **Inline image inside emphasis or a link** (`*![a](b.png)*`, `[![a](b.png)](https://x)`): no character hidden twice, the link still follows on click. → Task 7 `testImageInsideEmphasisAndLink`, Task 9 `testClickOnLinkedImageFollowsLink`.
3. **Editing a revealed image's address, then leaving it:** the new address loads and the picture changes; the old one is not shown for the new source. → Task 9, `testEditedAddressLoadsNewImage`.
4. **A huge inline image** (4000×1000 banner in a sentence): scaled to the height cap and never wider than the column; the line height does not change. → Task 8, `testHugeInlineImageIsCapped`.
5. **Theme or font size change with inline images shown:** the reserved width follows the new size. → Task 9, `testFontSizeChangeResizesInlineImage`.

---

### Task 1: `TVMVNativeText` target, platform aliases, attribute keys and theme

**Files:**
- Modify: `Package.swift` (new target, product, test target; `tvmv` depends on it)
- Create: `Sources/TVMVNativeText/Platform.swift`
- Move: `Sources/tvmv/NativeTheme.swift` → `Sources/TVMVNativeText/NativeTheme.swift` (with `git mv`)
- Modify: every `Sources/tvmv/*.swift` and `Tests/tvmvTests/*.swift` that uses the theme or keys: add `import TVMVNativeText`
- Test: `Tests/TVMVNativeTextTests/NativeThemeTests.swift`

**Interfaces:**
- Produces:
  - `public typealias PlatformFont = NSFont | UIFont`, `PlatformColor = NSColor | UIColor`, `PlatformImage = NSImage | UIImage` (one `#if` each).
  - `public enum FontTrait { case bold, italic }` and `extension PlatformFont { public func adding(_ trait: FontTrait) -> PlatformFont }` (AppKit: `NSFontManager.shared.convert(_:toHaveTrait:)`; UIKit: `fontDescriptor.withSymbolicTraits`, falling back to self).
  - `extension PlatformColor { public static func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> PlatformColor }`.
  - `public extension NSAttributedString.Key { tvmvHidden, tvmvNoSpell, tvmvLink, tvmvSoftBreak, tvmvReview }` (moved unchanged).
  - `public struct NativeTheme` with all current members public and `PlatformFont`/`PlatformColor` types; `chromeColor` computed from `paper.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, …)` components instead of `usingColorSpace`.
- Package: `.target(name: "TVMVNativeText", dependencies: ["TVMVCore"])`, `.library(name: "TVMVNativeText", targets: ["TVMVNativeText"])`, `.testTarget(name: "TVMVNativeTextTests", dependencies: ["TVMVNativeText"])`; `tvmv` gains `"TVMVNativeText"`.

- [ ] **Step 1: Write the failing tests** in `NativeThemeTests`:
  - `testFullWidthHasNoColumn`: `NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16, measure: 80, fullWidth: true, dark: false).columnWidth == nil`.
  - `testHeadingScale`: `headingFont(1).pointSize == 32`, `headingFont(6).pointSize == 13.6` (accuracy 0.01) at size 16.
  - `testDarkPaperAndChrome`: dark `paper` sRGB components equal `0x18/255, 0x14/255, 0x10/255` (accuracy 0.002); `chromeColor` equals the value the current Mac code produces for the same theme (compute it once in the test from the literal `RGBAColor(red: 0x18/255, green: 0x14/255, blue: 0x10/255).blended(fraction: 0.16, of: .white)`).
  - `testAddingTraits`: `PlatformFont.systemFont(ofSize: 14).adding(.bold)` has the bold trait (AppKit: `NSFontManager.shared.traits(of:)` contains `.boldFontMask`).
- [ ] **Step 2: Run** `swift test --filter NativeThemeTests` (with `DEVELOPER_DIR`). Expected: build failure, no `TVMVNativeText` module.
- [ ] **Step 3: Create the target, move the theme and keys, add the aliases**, and add `import TVMVNativeText` where the Mac app and its tests need it.
- [ ] **Step 4: Run** `swift test` (whole suite). Expected: all pass, including the new tests.
- [ ] **Step 5: Run the iOS compile gate.** Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 6: Commit** `Native text: TVMVNativeText target with the theme and attribute keys`.

### Task 2: Styler

**Files:**
- Move: `Sources/tvmv/DocumentStyler.swift` → `Sources/TVMVNativeText/DocumentStyler.swift`
- Test: `Tests/TVMVNativeTextTests/DocumentStylerTests.swift`

**Interfaces:**
- Consumes: Task 1 aliases, `FontTrait`, `NativeTheme`.
- Produces: `public enum DocumentStyler` with `public static func apply(_ layout: MarkdownLayout, to storage: NSTextStorage, in range: NSRange, theme: NativeTheme, isRevealed: (NSRange) -> Bool, imageHeight: (MarkdownLayout.BlockImage) -> CGFloat? = { _ in nil }, tableHeight: (Int) -> CGFloat? = { _ in nil })` (signature unchanged), plus `listIndent(level:em:)` and `quoteIndent(level:em:)` public. `NSFontManager` trait conversion becomes `font.adding(.italic/.bold)`; `NSColor.clear` / `NSFont.systemFont` become the `PlatformColor` / `PlatformFont` equivalents.

- [ ] **Step 1: Write the failing tests** (plain `NSTextStorage`, no view):
  - `testDelimitersHide`: text `"Some **bold** text"`, after `apply` the characters at 5, 6, 11, 12 carry `.tvmvHidden`; 7 does not; the font at 7 has the bold trait.
  - `testRevealedUnitShowsMarkup`: same text with `isRevealed: { _ in true }` → no `.tvmvHidden` anywhere.
  - `testFenceLinesCollapse`: `"Para\n\n```\ncode\n```\n"`, the opening fence line carries `.tvmvHidden` and a paragraph style with `maximumLineHeight == 0.01`.
  - `testBlockImageReservesHeight`: `"![a](x.png)\n"` with `imageHeight: { _ in 100 }` → paragraph `minimumLineHeight == 100 + 16` at size 16.
- [ ] **Step 2: Run** `swift test --filter DocumentStylerTests`. Expected: FAIL (`DocumentStyler` not in `TVMVNativeText`).
- [ ] **Step 3: Move the styler** and replace its AppKit calls as listed.
- [ ] **Step 4: Run** `swift test` and the iOS compile gate. Expected: all pass; `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit** `Native text: move the styler`.

### Task 3: Layout-manager delegate

**Files:**
- Create: `Sources/TVMVNativeText/MarkupLayoutDelegate.swift`
- Modify: `Sources/tvmv/DocumentTextView.swift` (`Hooks` loses the three layout-manager methods; the view keeps a strong `let markupLayout = MarkupLayoutDelegate()` and sets `layoutManager?.delegate = markupLayout` in `configure()`)
- Test: `Tests/TVMVNativeTextTests/MarkupLayoutDelegateTests.swift`

**Interfaces:**
- Produces: `public final class MarkupLayoutDelegate: NSObject, NSLayoutManagerDelegate` implementing, unchanged in behavior:
  - `shouldGenerateGlyphs` (null glyph for `.tvmvHidden`, never for control characters),
  - `shouldUse … forControlCharacterAt` (`.whitespace` for `.tvmvSoftBreak`),
  - `boundingBoxForControlGlyphAt` (a soft break is a space wide in the run's font).
  Conformance is `@preconcurrency NSLayoutManagerDelegate` (the spike needed this under Swift 6).

- [ ] **Step 1: Write the failing tests** with a standalone `NSTextStorage` → `NSLayoutManager` → `NSTextContainer(size: 400×∞)` stack, the delegate set, attributes applied by `DocumentStyler`:
  - `testHiddenCharactersAreNullGlyphs`: in `"Some **bold** text"`, `propertyForGlyph(at: glyphIndexForCharacter(at: 5)) == .null`, and the x of character 7 equals the x of character 5 (accuracy 0.5).
  - `testSoftBreakIsASpace`: `"one\ntwo\n"` as one paragraph (soft break at 3): characters 0 and 4 lie on the same line fragment, and x(4) − x(2) is greater than the width of `"e"`.
- [ ] **Step 2: Run** `swift test --filter MarkupLayoutDelegateTests`. Expected: FAIL (type missing).
- [ ] **Step 3: Move the three methods** into `MarkupLayoutDelegate` and rewire the Mac view.
- [ ] **Step 4: Run** `swift test` and the iOS compile gate. Expected: all pass.
- [ ] **Step 5: Commit** `Native text: move the layout-manager delegate`.

### Task 4: Image loading

**Files:**
- Create: `Sources/TVMVNativeText/ImageStore.swift`
- Modify: `Sources/tvmv/DocumentTextView.swift` (MARK: Images section shrinks to `imageSize(for:)`, `restyleImages`, the store, and forwarding `imageState(for:)`, `maxImageBytes`, `maxImagePixels`)
- Modify: `Tests/tvmvTests/DocumentImageTests.swift` only where it calls the static helpers (`DocumentTextView.imageURL` → `ImageSource.url`)
- Test: `Tests/TVMVNativeTextTests/ImageStoreTests.swift`

**Interfaces:**
- Produces:
  - `public enum ImageSource` with `static func url(_ address: String, documentURL: URL?) -> URL?`, `nonisolated static func isInside(_:_:) -> Bool`, `nonisolated static func readLocal(_:folder:limit:) -> Data?`, `nonisolated static func download(_:limit:) async -> Data?` (bodies moved unchanged).
  - `public enum ImageDecoder { public static func decode(_ data: Data, maxPixels: Int) -> PlatformImage? }`: the raster check is shared (ImageIO); the vector-only branch (SVG/PDF) is `#if os(macOS)`; on iOS a non-raster image returns nil.
  - `@MainActor public final class ImageStore` with `public enum State: Equatable { case loading, loaded, failed }`, `public var maxBytes = 50_000_000`, `public var maxPixels = 100_000_000`, `public var documentURL: URL?`, `public func state(for address: String) -> State?`, `public func image(for address: String) -> PlatformImage?`, `public func request(_ addresses: [String], onLoaded: @escaping @MainActor (String) -> Void)` (requests each address once, as `requestImages` does now).

- [ ] **Step 1: Write the failing tests**:
  - `testAddressesOutsideTheFolderAreRefused`: `ImageSource.url("../x.png", documentURL: /tmp/d/doc.md)`, `"/etc/x.png"` and `"file:///x.png"` are nil; `"img/x.png"` resolves inside `/tmp/d`; `"https://e.com/x.png"` is returned as written.
  - `testDecoderRefusesOverPixelCap`: a 200×100 PNG decodes with `maxPixels: 20_000` and is nil with `maxPixels: 19_999`.
  - `testStoreLoadsOnceAndReports`: writing a PNG to a temp folder, `request(["a.png","a.png"])` calls `onLoaded` exactly once with `"a.png"`, then `state(for:) == .loaded`; a missing file ends `.failed`.
- [ ] **Step 2: Run** `swift test --filter ImageStoreTests`. Expected: FAIL.
- [ ] **Step 3: Move the helpers and build `ImageStore`**; the Mac view keeps one store and calls `request(layout.blockImages.map(\.url))`.
- [ ] **Step 4: Run** `swift test` (DocumentImageTests must pass unchanged in behavior) and the iOS compile gate.
- [ ] **Step 5: Commit** `Native text: move image loading and decoding`.

### Task 5: Decorations and geometry

**Files:**
- Create: `Sources/TVMVNativeText/DocumentDecorations.swift`, `Sources/TVMVNativeText/DocumentGeometry.swift`
- Modify: `Sources/tvmv/DocumentTextView.swift` (`drawBackground(in:)` calls `DocumentDecorations.draw`; `listItemGeometry`, `bulletAnchor`, `taskBoxRect`, `drawListsAndQuotes`, `drawImages`, `drawPointMarkers`, the code-block and pill drawing move out), `Sources/tvmv/NativeDocumentView.swift` (`topVisibleOffset` and `scrollTo(offset:)` use `DocumentGeometry`)
- Test: `Tests/TVMVNativeTextTests/DocumentDecorationsTests.swift`

**Interfaces:**
- Produces:
  - `public struct DecorationInput` holding: `layout: MarkdownLayout`, `theme: NativeTheme`, `storage: NSTextStorage`, `layoutManager: NSLayoutManager`, `textContainer: NSTextContainer`, `origin: CGPoint` (the text container origin in view coordinates), `isRevealed: (NSRange) -> Bool`, `isHidden: (Int) -> Bool`, `images: ImageStore`, `blockImageSize: (MarkdownLayout.BlockImage) -> CGSize?`, `codePillRuns: [MarkdownLayout.StyleRun]`, `pixelAlign: (CGRect) -> CGRect`.
  - `@MainActor public enum DocumentDecorations { public static func draw(_ input: DecorationInput, in rect: CGRect) }`: code-block backgrounds, inline-code pills, block images (or their "▨ alt" label), quote rules, bullets/numbers/checkboxes, point markers, in the current order. Shapes are drawn with `CGContext` paths (`CGPath(roundedRect:cornerWidth:cornerHeight:transform:)`) on the current context (`NSGraphicsContext.current?.cgContext` / `UIGraphicsGetCurrentContext()`), text with `NSString.draw(at:withAttributes:)`, images with a small `#if` helper `drawImage(_:in:)` (AppKit: `draw(in:from:operation:fraction:respectFlipped: true, hints:)`; UIKit: `draw(in:)`).
  - `public enum DocumentGeometry` with `static func listItem(_ item: MarkdownLayout.ListItem, _ input: DecorationInput) -> (fragment: CGRect, baseline: CGFloat, textX: CGFloat)?`, `static func taskBox(_ item:, _ input:) -> CGRect?`, `static func topVisibleOffset(y: CGFloat, layoutManager:, textContainer:, origin: CGPoint) -> Int`, `static func lineTop(offset: Int, layoutManager:, textContainer:) -> CGFloat`. The Mac view's `bulletAnchor(for:)`, `taskBoxRect(for:)`, `taskItem(at:)` become thin wrappers.

- [ ] **Step 1: Write the failing test** `testCheckedTaskDrawsAccentBox`: build storage + layout manager for `"- [x] done\n"`, style it, render `DocumentDecorations.draw` into a 400×100 bitmap `CGContext` (flipped to match a flipped view), and assert the pixel at the centre of `DocumentGeometry.taskBox` is the theme accent (±3 per channel). Add `testUncheckedTaskDrawsNoFill`: same with `[ ]`, the centre pixel is the paper/clear background.
- [ ] **Step 2: Run** `swift test --filter DocumentDecorationsTests`. Expected: FAIL.
- [ ] **Step 3: Move the drawing and geometry**, converting `NSBezierPath`/`NSRect.fill()` to `CGContext` calls; keep every constant (radii 6/4/3, insets −12/+24/−8/+16, pill pad `mono.pointSize * 0.14`, check-mark points, bullet glyphs `•◦▪`, offsets `0.45 em`) exactly as they are.
- [ ] **Step 4: Run** `swift test` (ListQuoteTests, DocumentImageTests, ReviewViewTests and NativeDocumentViewTests must pass unchanged) and the iOS compile gate.
- [ ] **Step 5: Manual Mac check:** `fish build/bundle.fish`, open `Fixtures/showcase.md`: code blocks, pills, bullets, checkboxes, quote rules, block images and point markers look as before (compare against a screenshot taken before Task 5).
- [ ] **Step 6: Commit** `Native text: move decoration drawing and geometry`.

### Task 6: Parse and reveal engine

**Files:**
- Create: `Sources/TVMVNativeText/MarkdownTextEngine.swift`
- Modify: `Sources/tvmv/DocumentTextView.swift` (`layout`, `revealedUnits`, `showAllMarkup`, `parseGeneration`, `parseInFlight`/`parseQueued`, `unchangedPrefix`/`unchangedSuffix`, `backgroundParsesStarted`, `recordEdit`'s bookkeeping, `textChanged`'s parse half, `applyParsed`, `restyle`'s styler call, `unitsEnclosingSelection`, `setRevealedUnits` move into the engine; the view keeps cell patches, `onEdit`, grids and review)
- Test: `Tests/TVMVNativeTextTests/MarkdownTextEngineTests.swift`

**Interfaces:**
- Consumes: `DocumentStyler.apply`, `ImageStore`.
- Produces:
  - `@MainActor public protocol MarkdownTextHost: AnyObject { var hasMarkedText: Bool { get }; func engine(_ engine: MarkdownTextEngine, didRestyle range: NSRange); func engine(_ engine: MarkdownTextEngine, didApply layout: MarkdownLayout) }`.
  - `@MainActor public final class MarkdownTextEngine` with `public static let syncParseLimit = 64 * 1024`, `public init(storage: NSTextStorage, host: MarkdownTextHost)`, `public private(set) var layout: MarkdownLayout`, `public var theme: NativeTheme`, `public var showAllMarkup: Bool`, `public private(set) var revealedUnits: [NSRange]`, `public private(set) var backgroundParsesStarted: Int`, `public var blockImageHeight: (MarkdownLayout.BlockImage) -> CGFloat?`, `public var tableHeight: (Int) -> CGFloat?`, and:
    - `func load(_ text: String)` (replace text, full parse, restyle all, `didApply`),
    - `func recordEdit(editedRange: NSRange, delta: Int)`,
    - `func textChanged()` (sync ≤ limit, otherwise one background parse at a time, latest wins, a queued re-parse after),
    - `func restyle(_ range: NSRange)`,
    - `func isRevealed(_ unit: NSRange) -> Bool`, `func units(enclosing selection: NSRange) -> [NSRange]`, `func setRevealedUnits(_ units: [NSRange])`.
  The generation, marked-text and length guards of `applyParsed` move as they are.

- [ ] **Step 1: Write the failing tests** with a fake host (records restyled ranges and applied layouts; `hasMarkedText` settable):
  - `testSmallEditParsesSynchronously`: load `"a *b* c"`, insert `"x"` at 0 through `storage.replaceCharacters` + `recordEdit` + `textChanged`; `didApply` fired once before `textChanged` returns, and `layout.length == 8`.
  - `testLargeDocumentParsesInBackgroundLatestWins`: a 70 KB text, two edits in a row; `backgroundParsesStarted == 1` immediately, and after awaiting (poll the main run loop up to 5 s) `layout.length == storage.length`.
  - `testMarkedTextBlocksApply`: `hasMarkedText = true`, an edit → no `didApply`; set false and call `textChanged()` → applied.
  - `testRevealRestylesTouchedRange`: `setRevealedUnits([unit of **b**])` → host saw a restyle covering that unit, and the stars are no longer `.tvmvHidden`.
- [ ] **Step 2: Run** `swift test --filter MarkdownTextEngineTests`. Expected: FAIL.
- [ ] **Step 3: Build the engine** by moving the code; `DocumentTextView` conforms to `MarkdownTextHost` (`didRestyle` → `relayParagraphs`, `layoutGrids`, `layoutReviewMargin`; `didApply` → `requestImages`, `onLayout`).
- [ ] **Step 4: Run** `swift test` (DocumentTextViewTests, PerformanceTests, TableGridTests, Review* must pass unchanged) and the iOS compile gate.
- [ ] **Step 5: Manual Mac pass:** bundle, open `Fixtures/showcase.md`; ⌘E, type in emphasis, ⌘' reveal and leave, ⌥⌘M, table cell edit + Tab, add and resolve a comment, Japanese IME inside `*…*`. All as before.
- [ ] **Step 6: Commit** `Native text: move the parse and reveal engine`.

### Task 7: Inline images in the layout

**Files:**
- Modify: `Sources/TVMVCore/MarkdownLayout.swift` (new type and list, `revealUnits`), `Sources/TVMVCore/MarkdownLayoutParser.swift` (the `"image"` case), `Sources/TVMVCore/MarkdownLayoutDiff.swift` (widen), `Sources/TVMVCore/ReviewLayout.swift` (drop inline images that meet opaque review ranges, as for block images)
- Test: `Tests/TVMVCoreTests/MarkdownLayoutParserTests.swift`, `Tests/TVMVCoreTests/MarkdownLayoutPropertyTests.swift`

**Interfaces:**
- Produces: `public struct MarkdownLayout.InlineImage: Equatable, Sendable { public var range: NSRange; public var url: String; public var alt: String; public var altRange: NSRange }` (`range` is the whole `![alt](url "title")` and its reveal unit; `altRange` is the alt text between `![` and `]`), `public var inlineImages: [InlineImage]`, and `revealUnits` including `inlineImages.map(\.range)`.
- Rule: every cmark `image` node whose range is not a recorded block image becomes an inline image, including inside links and emphasis. The `.image` style run and spell exemption stay as they are.
- Golden corpus: `inlineImages` is **not** added to `GoldenLayoutTests.describe` in this plan. The JSON is generated by the Rust port on Linux, which cannot run here; the key is added with the Linux port (spec: Deferred). This is a deviation from the spec's build-order note and is recorded in the spec in Task 9.

- [ ] **Step 1: Write the failing tests** in `MarkdownLayoutParserTests`:
  - `testInlineImageInSentence`: `"A ![b](x.png) c"` → `inlineImages == [.init(range: 2+11, url: "x.png", alt: "b", altRange: 4+1)]`, `blockImages` empty.
  - `testBlockImageIsNotInline`: `"![b](x.png)\n"` → `inlineImages` empty, one block image.
  - `testImageInsideEmphasisAndLink`: `"*![a](b.png)* [![c](d.png)](https://x)"` → two inline images; a `.link(url: "https://x")` style covers the second; no character index appears in two markers' ranges.
  - `testImageInCodeIsNot`: ``"`![a](b.png)`"`` → no inline images.
  - `testInlineImageIsARevealUnit`: its range is in `revealUnits`.
- [ ] **Step 2: Extend the random-edit property test** in `MarkdownLayoutPropertyTests` so the diffed layout's `inlineImages` equal a full parse's (the existing harness compares layouts with `==`; confirm the new field is covered and add `"![a](b.png)"` to its edit alphabet).
- [ ] **Step 3: Run** `swift test --filter "MarkdownLayoutParserTests|MarkdownLayoutPropertyTests"`. Expected: the new tests FAIL.
- [ ] **Step 4: Implement** the type, the parser case, the diff widen (same closure shape as `blockImages`) and the review filter.
- [ ] **Step 5: Run** `swift test` (GoldenLayoutTests must still pass: the description is unchanged). Expected: all pass.
- [ ] **Step 6: Commit** `Layout: inline images`.

### Task 8: Inline images in the styler, decorations and engine

**Files:**
- Modify: `Sources/TVMVNativeText/NativeTheme.swift` (attribute key), `DocumentStyler.swift`, `DocumentDecorations.swift`, `MarkdownTextEngine.swift`, `ImageStore` call sites
- Create: `Sources/TVMVNativeText/InlineImageMetrics.swift`
- Test: `Tests/TVMVNativeTextTests/InlineImageStylerTests.swift`

**Interfaces:**
- Consumes: `MarkdownLayout.inlineImages` (Task 7), `ImageStore` (Task 4).
- Produces:
  - `NSAttributedString.Key.tvmvImageCarrier` (value: the image's address).
  - `public enum InlineImageMetrics { public static func size(natural: CGSize, theme: NativeTheme, column: CGFloat) -> CGSize }`: scale down (never up) to height ≤ `1.4 × theme.body.pointSize` and width ≤ `column`, keeping the aspect ratio. *(Builder's call per spec: 1.4 em stays inside the 1.7 em body line, so a line's height never changes. The spec's "a taller picture raises its line" therefore never applies.)*
  - `DocumentStyler.apply` gains `inlineImageSize: (MarkdownLayout.InlineImage) -> CGSize? = { _ in nil }`. For an inline image that is not revealed:
    - **size known (loaded):** every character of `range` except the first (`!`) gets `.tvmvHidden`; the first gets `.tvmvImageCarrier`, `.foregroundColor: clear`, and `.kern = size.width − width("!" in its font)`.
    - **size unknown (loading or failed):** `![` and `](…)` get `.tvmvHidden`; `altRange` gets `theme.muted`. If `altRange` is empty, the URL's last path component is left visible instead (only `![](` and `)` hide).
  - `DocumentStyler.apply` gains `blockImagesInline: Bool = false`: when true (table cells), block images are styled as inline images (a cell is one line).
  - `MarkdownTextEngine` gains `public var inlineImageSize: (MarkdownLayout.InlineImage) -> CGSize?` and `public var treatsBlockImagesAsInline = false`, passed to the styler; its image request covers `inlineImages` addresses too.
  - `DecorationInput` gains `inlineImageSize: (MarkdownLayout.InlineImage) -> CGSize?`.
  - `DocumentDecorations.draw` draws each shown inline image with its bottom on the carrier's baseline, x at the carrier glyph's location, size from `inlineImageSize`, through `pixelAlign`.

- [ ] **Step 1: Write the failing tests** (`NSTextStorage` + layout manager + `MarkupLayoutDelegate`):
  - `testLoadedInlineImageReservesWidth`: `"A ![b](x.png) c"`, `inlineImageSize: { _ in CGSize(width: 40, height: 20) }` → characters 3…12 `.tvmvHidden`, character 2 has `.tvmvImageCarrier == "x.png"`; x(14) − x(2) equals 40 + the width of `" "` (accuracy 0.5).
  - `testUnloadedInlineImageShowsAlt`: no size → `"b"` (index 4) not hidden and muted; `![` and `](x.png)` hidden.
  - `testEmptyAltShowsFileName`: `"![](img/x.png)"` unloaded → `x.png` visible.
  - `testHugeInlineImageIsCapped`: `InlineImageMetrics.size(natural: 4000×1000, theme@16, column: 600)` → height 22.4, width 89.6; a natural 30×10 stays 30×10; a natural 2000×20 → width 600, height 6.
  - `testCellTreatsBlockImageAsInline`: `"![b](x.png)"` with `blockImagesInline: true` and a size → no paragraph `minimumLineHeight` beyond the body's; carrier present.
- [ ] **Step 2: Run** `swift test --filter InlineImageStylerTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the metrics, key, styler branches, engine plumbing and drawing.
- [ ] **Step 4: Run** `swift test` and the iOS compile gate. Expected: all pass.
- [ ] **Step 5: Commit** `Native text: inline images in the styler and decorations`.

### Task 9: Inline images in the Mac view

**Files:**
- Modify: `Sources/tvmv/DocumentTextView.swift` (`isHidden`, delete handling, image request/restyle, `inlineImageSize`), `Sources/tvmv/TableGridView.swift` (cells set `treatsBlockImagesAsInline = true`), `README.md` (macOS section: inline images), `docs/superpowers/specs/2026-11-02-ios-native-editor-design.md` (note: golden key deferred to the Linux port)
- Test: `Tests/tvmvTests/DocumentImageTests.swift`

**Interfaces:**
- Consumes: Tasks 4, 6, 8.
- Produces (behavior):
  - `isHidden(_:)` — used by caret snap, delete retarget and copy — is true for `.tvmvHidden` **or** `.tvmvImageCarrier`, so an inline image is one hidden run for `EditRules`: the caret rests only before or after it. The glyph delegate still nulls only `.tvmvHidden`.
  - A one-character Backspace whose range ends at `NSMaxRange(image.range)`, or Delete starting at `image.range.location`, deletes the whole image source as one undoable edit (checked in `shouldChangeTextIn` before `EditRules.retargetDelete`).
  - `inlineImageSize` = `InlineImageMetrics.size(natural: store image size, theme:, column: container width − 2 × padding)`.
  - When an image finishes loading, every inline and block image with that address is restyled.

- [ ] **Step 1: Write the failing tests** in `DocumentImageTests` (existing window/folder harness, `writePNG`, `pump`):
  - `testInlineImageShowsAsPicture`: write `img/dot.png` 16×16; load `"A ![b](img/dot.png) c\n"`; after load, the carrier is not null-glyph, characters after it are, and `imageState == .loaded`.
  - `testUnloadedInlineImageShowsAlt`: missing file → after `.failed`, the `b` glyph is not null.
  - `testCaretPassesInlineImageInOneStep`: ⌘E, caret at 2 (before `!`), `moveRight(nil)` → caret at `NSMaxRange(image.range)`; `moveLeft(nil)` → back at 2.
  - `testBackspaceDeletesWholeInlineImage`: caret after the image, `deleteBackward(nil)` → text is `"A  c\n"`; `undoManager.undo()` restores it byte for byte.
  - `testClickOnLinkedImageFollowsLink`: `"[![b](img/dot.png)](https://x.example)"`, read-only: `link(at:)` at the picture's centre returns `"https://x.example"`.
  - `testEditedAddressLoadsNewImage`: reveal the image (⌘'), replace `dot.png` with `dot2.png` (written 32×16), move the caret away → `imageState(for: "img/dot2.png") == .loaded` and the reserved width is the 32×16 picture's capped width.
  - `testFontSizeChangeResizesInlineImage`: change `theme` to size 24 → x after the image moves by the new capped width (accuracy 0.5).
- [ ] **Step 2: Run** `swift test --filter DocumentImageTests`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** the view changes and the cell flag.
- [ ] **Step 4: Run** the whole suite and the iOS compile gate. Expected: all pass.
- [ ] **Step 5: Manual Mac check:** bundle; a document with a shields.io badge line, an inline icon in a sentence, an image inside a link, and an image in a table cell; each shows as a picture, reveals with ⌘', and prints unchanged.
- [ ] **Step 6: Update the README** (macOS: "images, inline and block, show as pictures") and add one line to the spec's Inline images section: "The golden-corpus key follows with the Linux port."
- [ ] **Step 7: Commit** `Inline images render as pictures on macOS`.
