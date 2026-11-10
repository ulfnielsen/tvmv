import AppKit
import TVMVCore
import TVMVNativeText

/// The native reader/editor: one TextKit 1 text view in which Markdown
/// renders in place with its markup hidden.
///
/// - Hiding: markers carry `.tvmvHidden`; the layout-manager delegate turns
///   those characters into null glyphs. The text itself never changes.
/// - Parsing and styling: `MarkdownTextEngine`, with this view as its host.
/// - Reveal: double-click or ⌘' shows the markup of the span(s) under the
///   selection until Esc or the selection leaves them; ⌥⌘M shows all markup.
final class DocumentTextView: NSTextView, MarkdownTextHost {
    /// Parses and styles the text storage.
    private(set) lazy var engine = MarkdownTextEngine(storage: textStorage!, host: self)

    var layout: MarkdownLayout { engine.layout }
    var theme: NativeTheme {
        get { engine.theme }
        set { engine.theme = newValue; applyTheme() }
    }
    var showAllMarkup: Bool {
        get { engine.showAllMarkup }
        set { engine.showAllMarkup = newValue }
    }
    /// Draw with AppKit font smoothing (stroke thickening). Off, as in the
    /// web reader (-webkit-font-smoothing: antialiased).
    var fontSmoothing = false {
        didSet { needsDisplay = true }
    }
        /// True after a reveal request, until the selection leaves every revealed unit.
    private(set) var revealing = false

    /// Every text change, as a patch against the previous text plus the new length.
    var onEdit: ((TextPatcher.Patch, Int) -> Void)?
    /// A new layout was applied (headings may have changed).
    var onLayout: ((MarkdownLayout) -> Void)?
    /// A link was activated (read-only click, or ⌘-click while editing).
    var onFollowLink: ((String) -> Void)?
    /// Called once, the first time the view gets a non-zero width.
    var onSized: (() -> Void)?
    /// The document's file: relative image paths resolve against its folder.
    var documentURL: URL? {
        didSet { imageStore.documentURL = documentURL }
    }
    /// Set on a table cell's editor: the grid it belongs to.
    weak var cellHost: TableGridView?
    var isCell: Bool { cellHost != nil }
    /// One grid per table in `layout.tables`, in order.
    private(set) var tableGrids: [TableGridView] = []
    private var tableHeights: [Int: CGFloat] = [:]
    /// Review margin: cards beside their anchors when the margin is wide
    /// enough, otherwise markers that open a card in a popover.
    var reviewCards: [ReviewCardView] = []
    var reviewModels: [ReviewCards.Model] = []
    /// The thread whose card is focused (by the caret, or a click on the card).
    var focusedReviewID: String?
    /// The height the comment cards need (the frame never gets shorter).
    var reviewMinHeight: CGFloat = 0
    /// The text column is narrowed for the comment column.
    var showsReviewColumn = false
    /// The theme the cards and markers were built with.
    var reviewTheme: NativeTheme?
    var layingOutReview = false
    /// The focus moved mid-layout: show the focused card once it is placed.
    var revealsFocusedCard = false
    /// The comment or suggestion being written (⌘⇧M, ⌘⇧E), in the side column.
    var reviewComposer: ReviewComposerView?
    private var layingOutGrids = false
    /// Grid layout passes, and grids re-measured in them (observability).
    private(set) var gridLayoutPasses = 0
    private(set) var gridUpdates = 0
    /// True from a text change until it has been handled: caret moves an
    /// edit causes don't end a reveal.
    private var editing = false
    /// A cell's edits wait here until its edit has finished processing.
    private var pendingCellPatches: [TextPatcher.Patch] = []

    override var isEditable: Bool {
        didSet { if !isCell { tableGrids.forEach { $0.setEditable(isEditable) } } }
    }

    typealias ImageState = ImageStore.State
    private let ownImages = ImageStore()
    /// A table cell shares its document's images (and so its file): each
    /// address loads once, and the document restyles the cells using it.
    var imageStore: ImageStore { cellHost?.document?.imageStore ?? ownImages }
    /// Images that settled and wait to be restyled (once per turn).
    private var settledImages: Set<String> = []

    /// An image's state as shown: one that settled shows as loading until
    /// it is restyled.
    func imageState(for address: String) -> ImageState? {
        if let document = cellHost?.document { return document.imageState(for: address) }
        return settledImages.contains(address) ? .loading : imageStore.state(for: address)
    }
    var imageLoadsStarted: Int { imageStore.loadsStarted }
    /// A document is untrusted: cap what one image may cost.
    var maxImageBytes: Int {
        get { imageStore.maxBytes }
        set { imageStore.maxBytes = newValue }
    }
    var maxImagePixels: Int {
        get { imageStore.maxPixels }
        set { imageStore.maxPixels = newValue }
    }

    /// Private undo stack: the window's document undo manager belongs to a
    /// DocumentGroup(viewing:) document that can't be saved, and registering
    /// edits there triggers autosave alerts (see CodeMirrorEditorPane's history).
    private(set) var documentUndo = UndoManager()
    override var undoManager: UndoManager? { documentUndo }

    private let hooks = Hooks()
    /// Held here: a layout manager's delegate is weak.
    private let markupLayout = MarkupLayoutDelegate()
    /// Background parses started (observability for large-document typing).
    var backgroundParsesStarted: Int { engine.backgroundParsesStarted }

    /// `cell`: a table cell. Nothing observes a cell's frame, and AppKit's
    /// cost to post a frame change grows with the number of text views, so
    /// a cell posts none: with them, a page of tables loaded in quadratic time.
    static func make(cell: Bool = false) -> DocumentTextView {
        let view = DocumentTextView(usingTextLayoutManager: false)   // TextKit 1: null glyphs
        if cell { view.postsFrameChangedNotifications = false }
        view.configure()
        return view
    }

    private func configure() {
        hooks.view = self
        delegate = hooks
        engine.blockImageHeight = { [weak self] in self?.imageSize(for: $0)?.height }
        engine.inlineImageSize = { [weak self] in self?.inlineImageSize(for: $0) }
        engine.tableHeight = { [weak self] in self?.tableHeights[$0] }
        engine.diagramHeight = { [weak self] in self?.diagramImage(for: $0)?.size.height }
        layoutManager?.delegate = markupLayout
        textStorage?.delegate = hooks
        isRichText = false
        allowsUndo = true
        isEditable = false
        isSelectable = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = true
        textContainer?.widthTracksTextView = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        applyTheme()
    }

    // MARK: Content

    /// Replace the whole text (initial load, external reload). Not undoable.
    func load(_ text: String) {
        guard textStorage != nil else { return }
        closeComposer()   // its selection was in the old text
        // Replacing the storage directly registers no undo.
        documentUndo.removeAllActions()
        pendingCellPatches = []
        hooks.loading = true
        engine.load(text)
        hooks.loading = false
    }

    /// True while the app (not a keystroke) is changing the text.
    fileprivate var applyingEdit = false

    /// Replace `range` through the undoable edit path, exactly as asked: the
    /// keystroke rules around hidden markup do not apply.
    @discardableResult
    func replace(_ range: NSRange, with string: String) -> Bool {
        applyingEdit = true
        defer { applyingEdit = false }
        guard shouldChangeText(in: range, replacementString: string) else { return false }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
        return true
    }

    // MARK: Parse + restyle

    /// Called by the storage delegate for every character edit.
    fileprivate func recordEdit(editedRange: NSRange, delta: Int) {
        guard let storage = textStorage else { return }
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        engine.recordEdit(editedRange: editedRange, delta: delta)
        let insert = (storage.string as NSString).substring(with: editedRange)
        let patch = TextPatcher.Patch(from: oldRange.location, to: NSMaxRange(oldRange), insert: insert)
        editing = true
        if isCell { pendingCellPatches.append(patch) }
        onEdit?(patch, storage.length)
    }

    /// Re-parse after edits (called from textDidChange, outside processEditing).
    fileprivate func textChanged() {
        defer { editing = false }
        guard !hasMarkedText() else { return }
        if let host = cellHost, !pendingCellPatches.isEmpty {
            let patches = pendingCellPatches
            pendingCellPatches = []
            patches.forEach { host.cellDidEdit(self, $0) }
        }
        engine.textChanged()
    }

    /// Composition can end without a text change (no textDidChange), so
    /// re-parse here too.
    override func unmarkText() {
        super.unmarkText()
        textChanged()
    }

    func restyle(_ range: NSRange) { engine.restyle(range) }

    // MARK: MarkdownTextHost

    var hasMarkedText: Bool { hasMarkedText() }

    func engine(_ engine: MarkdownTextEngine, didRestyle range: NSRange) {
        // TextKit re-lays out an edit from the line after the previous
        // newline, assuming a newline ends a line. In a reflowed paragraph a
        // soft break doesn't, so re-lay the whole paragraph from its start.
        relayParagraphs(touching: range)
        guard !restylingImages else { return }   // laid out once, after them all
        layoutGrids()
        layoutReviewMargin()
    }

    func engine(_ engine: MarkdownTextEngine, didApply layout: MarkdownLayout) {
        requestImages()
        requestDiagrams()
        onLayout?(layout)
    }

    /// Until the parse lands (later, in large documents), keep the edited
    /// paragraph laid out from its start.
    func engine(_ engine: MarkdownTextEngine, willParse edit: NSRange) {
        relayParagraphs(touching: edit)
    }

    func engine(_ engine: MarkdownTextEngine, didInstall layout: MarkdownLayout) {
        updateRevealedUnits()
    }

    /// Invalidate layout from the start of every top-level paragraph that
    /// `range` touches (see restyle).
    private func relayParagraphs(touching range: NSRange) {
        guard let storage = textStorage else { return }
        let paragraphs = layout.blocks.filter {
            $0.kind == "paragraph"
                && (NSIntersectionRange($0.range, range).length > 0 || NSLocationInRange(range.location, $0.range))
        }
        let extent = paragraphs.reduce(range) { NSUnionRange($0, $1.range) }
        layoutManager?.invalidateLayout(forCharacterRange: NSIntersectionRange(extent, NSRange(location: 0, length: storage.length)),
                                        actualCharacterRange: nil)
        typingAttributes = theme.base
        needsDisplay = true
    }

    private func applyTheme() {
        backgroundColor = theme.paper
        insertionPointColor = theme.ink
        selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.18)]
        layoutColumn()
        requestDiagrams()   // drawn in the theme's colors and size
        restyle(NSRange(location: 0, length: textStorage?.length ?? 0))
    }

    /// Center a column of `theme.columnWidth` (or fill the width) with at least `theme.padding` each side.
    /// Re-lay the column and what follows it: images scale with its width,
    /// tables and comment cards follow its width and position.
    func columnChanged() {
        let column = textContainer?.size.width
        layoutColumn()
        if textContainer?.size.width != column {
            _ = restyleImages { _ in true }
            restyleDiagrams { _ in true }
        }
        layoutGrids()
        layoutReviewMargin()
    }

    /// Make `change` (one that rewraps the text) and scroll so the line being
    /// worked on stays where it was on screen: the selection's when it is in
    /// sight, else the top one. The comment column coming or going would
    /// otherwise move what is being read.
    func keepingLineInPlace(_ change: () -> Void) {
        guard let lm = layoutManager, let tc = textContainer, let length = textStorage?.length, length > 0
        else { change(); return }
        func lineTop(_ character: Int) -> CGFloat {
            lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: character), effectiveRange: nil).minY
                + textContainerOrigin.y
        }
        let visible = visibleRect
        var character = min(selectedRange().location, length - 1)
        if !(visible.minY..<visible.maxY).contains(lineTop(character)) {
            guard visible.minY > 0 else { change(); return }
            // One point below the edge, as for the reading position.
            let point = NSPoint(x: 0, y: visible.minY - textContainerOrigin.y + 1)
            character = min(lm.characterIndexForGlyph(at: lm.glyphIndex(for: point, in: tc)), length - 1)
        }
        let offset = lineTop(character) - visible.minY
        change()
        // Lay out to the line and grow to match, or the scroll is clamped.
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: character + 1))
        sizeToFit()
        scroll(NSPoint(x: 0, y: max(0, lineTop(character) - offset)))
    }

    func layoutColumn() {
        guard let container = textContainer else { return }
        if isCell {   // a table cell fills its frame, inside its own inset
            container.containerSize = NSSize(width: max(1, bounds.width - 2 * textContainerInset.width),
                                             height: .greatestFiniteMagnitude)
            return
        }
        // With comments, the column on the right takes the place of the
        // right padding; the text stays centred while the cards fit beside it.
        let reserve = reviewColumnReserve
        let available = max(200, bounds.width - theme.padding - (reserve > 0 ? reserve : theme.padding))
        let width = min(theme.columnWidth ?? available, available)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        var x = max(theme.padding, (bounds.width - width) / 2)
        if reserve > 0, x + width + reserve > bounds.width { x = max(theme.padding, bounds.width - reserve - width) }
        textContainerInset = NSSize(width: x, height: 36)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        var newSize = newSize
        if isVerticallyResizable { newSize.height = max(newSize.height, reviewMinHeight) }
        super.setFrameSize(newSize)
        if newSize.width != oldWidth { columnChanged() } else { layoutColumn() }
        if newSize.width > 0, let sized = onSized {
            onSized = nil
            sized()
        }
    }

    // MARK: Reveal

    /// Show the markup of the unit(s) enclosing the selection (on), or hide it again (off).
    func reveal(_ on: Bool) {
        setRevealedUnits(on ? engine.units(enclosing: selectedRange()) : [])
    }

    /// Reveal one unit and put the caret at its start (a table revealed from
    /// one of its cells: its source is hidden until revealed, so the caret
    /// could not be placed in it first).
    func reveal(unit: NSRange) {
        setRevealedUnits([unit])
        setSelectedRange(NSRange(location: unit.location, length: 0))
    }

    func toggleShowAllMarkup() { showAllMarkup.toggle() }

    private func setRevealedUnits(_ units: [NSRange], keepRevealing: Bool = false) {
        revealing = keepRevealing || !units.isEmpty
        engine.setRevealedUnits(units)
    }

    /// Selection moved: a reveal ends once the selection leaves every revealed unit.
    fileprivate func selectionChanged() {
        guard revealing, !editing else { return }   // the user moved, not an edit
        let current = Set(engine.units(enclosing: selectedRange()))
        if !engine.revealedUnits.contains(where: current.contains) { setRevealedUnits([]) }
    }

    /// After a re-parse, revealed units are re-found around the selection
    /// (their ranges moved with the edit).
    /// While the source being revealed is edited it can stop parsing as its
    /// construct for a moment (an image missing its ")"): stay revealing, so
    /// it shows again as source, not as the picture, once it is valid again.
    private func updateRevealedUnits() {
        if revealing { setRevealedUnits(engine.units(enclosing: selectedRange()), keepRevealing: true) }
    }

    /// Code, URLs and other exempt ranges never get spelling or grammar marks.
    func isSpellExempt(_ range: NSRange) -> Bool {
        guard let storage = textStorage else { return false }
        let range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        var exempt = false
        storage.enumerateAttribute(.tvmvNoSpell, in: range) { value, _, stop in
            if value != nil { exempt = true; stop.pointee = true }
        }
        return exempt
    }

    func isHidden(_ index: Int) -> Bool {
        guard let storage = textStorage, index >= 0, index < storage.length else { return false }
        return storage.attribute(.tvmvHidden, at: index, effectiveRange: nil) != nil
    }

    // MARK: Pictures in the text

    /// The sources of the images shown as pictures in the text: its inline
    /// images (in a table cell, its block images too) that carry one.
    func shownImages() -> [NSRange] {
        guard let storage = textStorage else { return [] }
        let images = layout.inlineImages.map(\.range)
            + (engine.treatsBlockImagesAsInline ? layout.blockImages.map(\.range) : [])
        return images.filter {
            NSMaxRange($0) <= storage.length && storage.attribute(.tvmvImageCarrier, at: $0.location, effectiveRange: nil) != nil
        }
    }

    /// Where a caret requested at `location` rests: never inside a
    /// picture's source (it rests right before or after it, at a line start
    /// or between two pictures too); elsewhere the hidden-markup rules apply.
    fileprivate func caretStop(_ location: Int, movingForward forward: Bool) -> Int {
        guard let storage = textStorage else { return location }
        let images = shownImages()
        func inside(_ i: Int) -> NSRange? { images.first { $0.location < i && i < NSMaxRange($0) } }
        if let image = inside(location) { return forward ? NSMaxRange(image) : image.location }
        if images.contains(where: { $0.location == location || NSMaxRange($0) == location }) { return location }
        let stop = EditRules.snapCaret(location, movingForward: forward, in: storage.string as NSString, isHidden: isHidden)
        return inside(stop).map { forward ? NSMaxRange($0) : $0.location } ?? stop
    }

    /// An arrow key from beside hidden markup passes that markup and then
    /// one visible character, or one picture (AppKit steps from glyph to
    /// glyph: across null glyphs it can propose the document's start, or
    /// pass a picture's edge or several pictures at once). Nil, for
    /// AppKit's own step: a selection, all markup shown, no markup hidden
    /// that way, or a hidden line break (a collapsed line or table).
    private func arrowStep(forward: Bool) -> Int? {
        guard !showAllMarkup, selectedRange().length == 0, let storage = textStorage else { return nil }
        let images = shownImages()
        let text = storage.string as NSString
        let caret = selectedRange().location
        var i = caret
        if forward {
            while true {
                if let image = images.first(where: { $0.location == i }) { return NSMaxRange(image) }
                guard i < text.length, isHidden(i) else { break }
                guard text.character(at: i) != 10 else { return nil }
                i += 1
            }
            guard i > caret else { return nil }
            let next = i < text.length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: i)) : i
            return caretStop(next, movingForward: true)
        }
        while true {
            if let image = images.first(where: { NSMaxRange($0) == i }) { return image.location }
            guard i > 0, isHidden(i - 1) else { break }
            guard text.character(at: i - 1) != 10 else { return nil }
            i -= 1
        }
        guard i < caret else { return nil }
        let previous = i > 0 ? text.rangeOfComposedCharacterSequence(at: i - 1).location : i
        return caretStop(previous, movingForward: false)
    }

    override func moveRight(_ sender: Any?) {
        if let stop = arrowStep(forward: true) { setSelectedRange(NSRange(location: stop, length: 0)) } else { super.moveRight(sender) }
    }

    override func moveLeft(_ sender: Any?) {
        if let stop = arrowStep(forward: false) { setSelectedRange(NSRange(location: stop, length: 0)) } else { super.moveLeft(sender) }
    }

    /// What a one-character Backspace (or forward Delete) removes when it
    /// reaches a picture over nothing but hidden markup: the whole image, or
    /// the whole link when the picture is all the link shows. Nil otherwise.
    fileprivate func pictureDelete(_ range: NSRange, caret: Int) -> NSRange? {
        guard range.length == 1, let storage = textStorage else { return nil }
        let text = storage.string as NSString
        let images = shownImages()
        var image: NSRange?
        if caret == NSMaxRange(range) {
            var end = NSMaxRange(range)
            while true {
                if let found = images.first(where: { NSMaxRange($0) == end }) { image = found; break }
                guard end > 0, isHidden(end - 1), text.character(at: end - 1) != 10 else { return nil }
                end -= 1
            }
        } else {
            var start = range.location
            while true {
                if let found = images.first(where: { $0.location == start }) { image = found; break }
                guard start < text.length, isHidden(start), text.character(at: start) != 10 else { return nil }
                start += 1
            }
        }
        guard let image else { return nil }
        // A link's text run is its label; its "[" marker's unit is the whole link.
        let isLinkLabel = layout.styles.contains { run in
            if case .link = run.style { return run.range == image }
            return false
        }
        guard isLinkLabel else { return image }
        return layout.markers.first { $0.range.location == image.location - 1 && $0.unit.location == $0.range.location }?.unit
            ?? image
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, revealDiagram(at: convert(event.locationInWindow, from: nil)) { return }
        if event.clickCount == 1, let task = taskItem(at: convert(event.locationInWindow, from: nil)) {
            toggleTask(task)
            return
        }
        if event.clickCount == 1, !isEditable || event.modifierFlags.contains(.command),
           let url = link(at: convert(event.locationInWindow, from: nil)) {
            onFollowLink?(url)
            return
        }
        super.mouseDown(with: event)
        if event.clickCount == 2 { reveal(true) }
    }

    func link(at point: NSPoint) -> String? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let index = lm.characterIndex(for: p, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < storage.length else { return nil }
        return storage.attribute(.tvmvLink, at: index, effectiveRange: nil) as? String
    }

    // MARK: Lists and quotes

    /// Where a list item's bullet is anchored: the x its text starts at and
    /// its first line's baseline, in view coordinates.
    func bulletAnchor(for item: MarkdownLayout.ListItem) -> NSPoint? {
        decorationInput().flatMap { DocumentGeometry.listItem(item, $0) }.map { NSPoint(x: $0.textX, y: $0.baseline) }
    }

    /// The clickable checkbox of a task item, in view coordinates.
    func taskBoxRect(for item: MarkdownLayout.ListItem) -> NSRect? {
        decorationInput().flatMap { DocumentGeometry.taskBox(item, $0) }
    }

    /// The task item whose checkbox is at `point` (with a little slack), if any.
    func taskItem(at point: NSPoint) -> Int? {
        guard let input = decorationInput() else { return nil }
        return layout.listItems.indices.first { i in
            !input.isRevealed(layout.listItems[i].marker)
                && DocumentGeometry.taskBox(layout.listItems[i], input)?.insetBy(dx: -4, dy: -4).contains(point) == true
        }
    }

    /// Check or uncheck a task item — allowed while reading too.
    func toggleTask(_ index: Int) {
        guard index < layout.listItems.count, let task = layout.listItems[index].task,
              let box = layout.listItems[index].checkbox else { return }
        let wasEditable = isEditable
        isEditable = true
        replace(box, with: task ? "[ ]" : "[x]")
        isEditable = wasEditable
    }

    /// Return on a list item's first line or a quoted line: continue it with
    /// the same prefix (the next number; an unchecked box), or end it when
    /// the line is empty. False if the caret is on neither.
    private func continueListOrQuote() -> Bool {
        guard isEditable, let storage = textStorage, selectedRange().length == 0 else { return false }
        let text = storage.string as NSString
        let caret = selectedRange().location
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        var lineEnd = NSMaxRange(line)
        if lineEnd > line.location, text.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
        let quote = layout.quoteLines.first { NSLocationInRange($0.prefix.location, line) }
        let item = layout.listItems.first { NSLocationInRange($0.marker.location, line) }
        guard item != nil || quote != nil else { return false }
        let prefixEnd = item.map { NSMaxRange($0.marker) } ?? NSMaxRange(quote!.prefix)
        guard caret >= prefixEnd else { return false }
        let content = text.substring(with: NSRange(location: prefixEnd, length: max(0, lineEnd - prefixEnd)))
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            let start = quote?.prefix.location ?? item!.marker.location
            if replace(NSRange(location: start, length: prefixEnd - start), with: "") {
                setSelectedRange(NSRange(location: start, length: 0))
            }
            return true
        }
        var next = quote.map { text.substring(with: $0.prefix) } ?? ""
        if let item {
            next += text.substring(with: NSRange(location: item.marker.location, length: item.bullet.location - item.marker.location))
            var bullet = text.substring(with: item.bullet)
            if item.ordered, let delimiter = bullet.last, let n = Int(bullet.dropLast()) { bullet = "\(n + 1)\(delimiter)" }
            next += bullet + " " + (item.task != nil ? "[ ] " : "")
        }
        if replace(NSRange(location: caret, length: 0), with: "\n" + next) {
            setSelectedRange(NSRange(location: caret + 1 + (next as NSString).length, length: 0))
        }
        return true
    }

    // MARK: Tables

    /// Inline code runs that get a pill: not those in a table's hidden
    /// source (its grid draws the cells).
    func codePillRuns() -> [MarkdownLayout.StyleRun] {
        let hiddenTables = layout.tables.map(\.range).filter { !engine.isRevealed($0) }
        return layout.styles.filter { run in
            run.style == .code && !hiddenTables.contains { NSIntersectionRange($0, run.range).length > 0 }
        }
    }

    /// Width the text needs on one line (a table column's natural width).
    /// Measured through the frame: the container can't outgrow the view.
    func naturalTextWidth() -> CGFloat {
        guard let lm = layoutManager, let tc = textContainer else { return 0 }
        let saved = frame.size
        setFrameSize(NSSize(width: 100_000, height: saved.height))
        lm.ensureLayout(for: tc)
        let width = lm.usedRect(for: tc).width
        setFrameSize(saved)
        return width
    }

    /// Height of the text laid out at `width` (text width, inside the inset).
    func textHeight(forWidth width: CGFloat) -> CGFloat {
        guard let lm = layoutManager, let tc = textContainer else { return 0 }
        setFrameSize(NSSize(width: max(1, width) + 2 * textContainerInset.width, height: frame.height))
        lm.ensureLayout(for: tc)
        return max(lm.usedRect(for: tc).height, theme.body.pointSize * 1.3)
    }

    /// Keep one grid per table, refreshed from the source and placed over its
    /// hidden lines; a grid's height change restyles the lines that reserve it.
    /// - Parameter only: the tables whose grids are refreshed (nil: all);
    ///   every grid is placed.
    func layoutGrids(only refreshed: IndexSet? = nil) {
        guard !isCell, !layingOutGrids, let storage = textStorage, let lm = layoutManager, let tc = textContainer
        else { return }
        layingOutGrids = true
        defer { layingOutGrids = false }
        gridLayoutPasses += 1
        while tableGrids.count > layout.tables.count { tableGrids.removeLast().removeFromSuperview() }
        let existing = tableGrids.count
        while tableGrids.count < layout.tables.count {
            let grid = TableGridView(document: self)
            addSubview(grid)
            tableGrids.append(grid)
        }
        let width = tc.size.width - 2 * tc.lineFragmentPadding
        for (i, table) in layout.tables.enumerated() where NSMaxRange(table.range) <= storage.length {
            let grid = tableGrids[i]
            grid.index = i
            grid.isHidden = engine.isRevealed(table.range)
            guard !grid.isHidden else { continue }
            if refreshed?.contains(i) ?? true || i >= existing {
                grid.update(table: table, text: storage.string as NSString, width: width, theme: theme, editable: isEditable)
                gridUpdates += 1
            }
            if tableHeights[i] != grid.frame.height {
                tableHeights[i] = grid.frame.height
                let heights = tableHeights, units = engine.revealedUnits, all = showAllMarkup
                DocumentStyler.apply(layout, to: storage, in: table.range, theme: theme,
                                     isRevealed: { all || units.contains($0) },
                                     imageHeight: { [weak self] in self?.imageSize(for: $0)?.height },
                                     tableHeight: { heights[$0] }, inlineImageSize: engine.inlineImageSize,
                                     blockImagesInline: engine.treatsBlockImagesAsInline)
            }
            // The first line is all hidden glyphs, which TextKit puts on the line
            // before; its reserved height is on the line starting at its newline.
            let text = storage.string as NSString
            let newline = max(table.range.location,
                              NSMaxRange(text.lineRange(for: NSRange(location: table.range.location, length: 0))) - 1)
            let fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: newline), effectiveRange: nil)
            grid.setFrameOrigin(NSPoint(x: textContainerOrigin.x + tc.lineFragmentPadding,
                                        y: fragment.minY + textContainerOrigin.y + theme.body.pointSize / 2))
        }
    }

    /// A cell's own edit, applied to that cell's source.
    func applyCellEdit(table index: Int, row: Int, column: Int, _ patch: TextPatcher.Patch) {
        engine.ensureCurrentLayout()
        guard index < layout.tables.count, row < layout.tables[index].rows.count,
              column < layout.tables[index].rows[row].count else { return }
        let source = TableSource.cellEdit(layout.tables[index], row: row, column: column, patch)
        replace(NSRange(location: source.from, length: source.to - source.from), with: source.insert)
    }

    /// A structural change: the table is rewritten neatly.
    func reformatTable(_ index: Int, _ change: (inout [[String]], inout [MarkdownLayout.Table.Alignment]) -> Void) {
        engine.ensureCurrentLayout()
        guard isEditable, index < layout.tables.count, let storage = textStorage else { return }
        let patch = TableSource.reformat(layout.tables[index], in: storage.string as NSString, change)
        replace(NSRange(location: patch.from, length: patch.to - patch.from), with: patch.insert)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if let host = cellHost { host.menuItems(for: self).forEach { menu?.addItem($0) } }
        // Comment on what's selected (or at the caret), while reading too.
        if !isCell, let menu {
            menu.insertItem(.separator(), at: 0)
            for (title, action) in [("Suggest Edit…", #selector(suggestReviewEdit(_:))),
                                    ("Comment…", #selector(addReviewComment(_:)))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.insertItem(item, at: 0)
            }
        }
        return menu
    }

    override func insertTab(_ sender: Any?) {
        if let host = cellHost { host.move(from: self, .next) } else { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if let host = cellHost { host.move(from: self, .previous) } else { super.insertBacktab(sender) }
    }

    // MARK: Images

    /// The size a loaded block image is drawn at: its own size, scaled down
    /// (never up) to the text column.
    private func imageSize(for image: MarkdownLayout.BlockImage) -> NSSize? {
        guard let picture = imageStore.image(for: image.url), picture.size.width > 0, let container = textContainer else { return nil }
        let column = container.size.width - 2 * container.lineFragmentPadding
        let width = min(picture.size.width, column)
        return NSSize(width: width, height: picture.size.height * width / picture.size.width)
    }

    /// The size a loaded inline image is drawn at in its line (in a table
    /// cell, its block images too).
    private func inlineImageSize(for image: MarkdownLayout.InlineImage) -> CGSize? {
        guard let picture = imageStore.image(for: image.url), picture.size.width > 0, let container = textContainer
        else { return nil }
        return InlineImageMetrics.size(natural: picture.size, theme: theme,
                                       column: container.size.width - 2 * container.lineFragmentPadding)
    }

    /// Start loading every block and inline image not yet requested (a
    /// table cell's too: the document requests them for its cells).
    private func requestImages() {
        guard !isCell else { return }
        imageStore.request(layout.blockImages.map(\.url) + layout.inlineImages.map(\.url)) { [weak self] address in
            self?.imageSettled(address)
        }
    }

    /// Images settle one by one: restyle those that settled in one turn
    /// together, with one grid pass.
    private func imageSettled(_ address: String) {
        if settledImages.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.restyleSettledImages() }
        }
        settledImages.insert(address)
    }

    private func restyleSettledImages() {
        let settled = settledImages
        settledImages = []
        guard !settled.isEmpty else { return }
        let tables = restyleImages(where: settled.contains)
        for i in tables where i < tableGrids.count { tableGrids[i].restyleImages(where: settled.contains) }
        layoutGrids(only: tables)
        layoutReviewMargin()
    }

    private var restylingImages = false

    /// The table whose source holds `location` (tables are in text order).
    private func tableIndex(at location: Int) -> Int? {
        let tables = layout.tables
        var low = 0, high = tables.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(tables[mid].range) <= location { low = mid + 1 } else { high = mid }
        }
        return low < tables.count && NSLocationInRange(location, tables[low].range) ? low : nil
    }

    /// Restyle the images `match` picks, laying out after them all (the
    /// caller places grids and the review margin). An image in a table's
    /// hidden source is its grid's: returns those tables.
    func restyleImages(where match: (String) -> Bool) -> IndexSet {
        var tables = IndexSet()
        restylingImages = true
        defer { restylingImages = false }
        for range in layout.blockImages.filter({ match($0.url) }).map(\.range)
            + layout.inlineImages.filter({ match($0.url) }).map(\.range) {
            if let i = tableIndex(at: range.location), !engine.isRevealed(layout.tables[i].range) {
                tables.insert(i)
            } else {
                restyle(range)
            }
        }
        return tables
    }

    // MARK: Diagrams

    /// Renders the document's Mermaid blocks and display math.
    var diagramRenderer = DiagramRenderer.shared
    /// Diagrams that settled and wait to be restyled (once per turn).
    private var settledDiagrams: Set<DiagramRenderer.Key> = []

    private func diagramKey(_ diagram: MarkdownLayout.Diagram) -> DiagramRenderer.Key { .init(diagram, theme: theme) }

    /// A rendered diagram's picture and the size it is drawn at: its own
    /// size, scaled down (never up) to the text column. Nil while rendering,
    /// after a failure, or settled but not yet restyled: its source shows.
    func diagramImage(for diagram: MarkdownLayout.Diagram) -> (image: NSImage, size: CGSize)? {
        let key = diagramKey(diagram)
        guard !isCell, !settledDiagrams.contains(key), let picture = diagramRenderer.image(for: key),
              picture.size.width > 0, let container = textContainer else { return nil }
        let column = container.size.width - 2 * container.lineFragmentPadding
        let width = min(picture.size.width, column)
        return (picture, CGSize(width: width, height: picture.size.height * width / picture.size.width))
    }

    private func requestDiagrams() {
        guard !isCell, !layout.diagrams.isEmpty else { return }
        diagramRenderer.request(layout.diagrams.map(diagramKey)) { [weak self] key in self?.diagramSettled(key) }
    }

    private func diagramSettled(_ key: DiagramRenderer.Key) {
        if settledDiagrams.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.restyleSettledDiagrams() }
        }
        settledDiagrams.insert(key)
    }

    private func restyleSettledDiagrams() {
        let settled = settledDiagrams
        settledDiagrams = []
        guard !settled.isEmpty else { return }
        restyleDiagrams(where: settled.contains)
        layoutGrids()
        layoutReviewMargin()
    }

    /// Reveal the source of the diagram drawn at `point` (a double-click
    /// on it: a click can't place the caret in its hidden source).
    func revealDiagram(at point: NSPoint) -> Bool {
        guard !showAllMarkup, let input = decorationInput(),
              let diagram = layout.diagrams.first(where: {
                  !engine.isRevealed($0.range) && DocumentDecorations.diagramRect(input, $0)?.contains(point) == true
              })
        else { return false }
        reveal(unit: diagram.range)
        return true
    }

    /// Restyle the diagrams `match` picks (the caller places grids and the review margin).
    private func restyleDiagrams(where match: (DiagramRenderer.Key) -> Bool) {
        restylingImages = true
        defer { restylingImages = false }
        for diagram in layout.diagrams where match(diagramKey(diagram)) { restyle(diagram.range) }
    }

    /// `rect` moved (not resized) so its origin sits on a device pixel.
    private func pixelAligned(_ rect: NSRect) -> NSRect {
        let backing = convertToBacking(rect.origin)
        let origin = convertFromBacking(NSPoint(x: backing.x.rounded(), y: backing.y.rounded()))
        return NSRect(origin: origin, size: rect.size)
    }

    // MARK: Copy

    /// What a copy or cut of `selection` takes: the selection widened over
    /// markup hidden at its edges (selecting a bold word copies "**word**",
    /// a heading's text "# Title", a code block's lines its fences too), so
    /// the clipboard gets Markdown, not the rendered text.
    func copyRange(for selection: NSRange) -> NSRange {
        guard !showAllMarkup, selection.length > 0, let storage = textStorage else { return selection }
        let text = storage.string as NSString
        var start = selection.location, end = NSMaxRange(selection)
        while start > 0, isHidden(start - 1) { start -= 1 }
        // A picture is copied whole, and only when the selection takes it.
        let images = shownImages()
        if let image = images.first(where: { $0.location < start && start < NSMaxRange($0) }) { start = NSMaxRange(image) }
        while end < text.length {
            if isHidden(end) { end += 1; continue }
            // A collapsed line right after (a closing fence): take it, newline and all.
            if text.character(at: end) == 10, end + 1 < text.length, isHidden(end + 1) {
                let run = EditRules.hiddenRun(at: end + 1, length: text.length, isHidden: isHidden)
                if text.character(at: NSMaxRange(run) - 1) == 10 { end = NSMaxRange(run); continue }
            }
            break
        }
        for image in images where start <= image.location && image.location < end { end = max(end, NSMaxRange(image)) }
        return NSRange(location: start, length: end - start)
    }

    /// Where copy and cut write (a test uses its own, not the clipboard).
    var pasteboard = NSPasteboard.general

    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        setSelectedRange(copyRange(for: selection))
        writeSelection(to: pasteboard, types: writablePasteboardTypes)
        setSelectedRange(selection)
    }

    override func cut(_ sender: Any?) {
        guard isEditable else { return }
        setSelectedRange(copyRange(for: selectedRange()))
        guard writeSelection(to: pasteboard, types: writablePasteboardTypes) else { return }
        delete(sender)
        undoManager?.setActionName("Cut")
    }

    // MARK: Pasting images

    override func paste(_ sender: Any?) {
        if !pasteImage(from: .general) { super.paste(sender) }
    }

    /// Paste an image (a screenshot, from Preview or a browser): save it as
    /// a PNG in an "images" folder beside the document and link it on its own
    /// line. Returns false — writing nothing — when there is text to paste
    /// instead, no image, no document folder, or editing is off.
    @discardableResult
    func pasteImage(from board: NSPasteboard) -> Bool {
        guard isEditable, !isCell, board.string(forType: .string) == nil,
              let document = documentURL, let storage = textStorage else { return false }
        let png: Data
        if let data = board.data(forType: .png) {
            png = data
        } else if let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) {
            png = data
        } else {
            return false
        }
        let folder = document.deletingLastPathComponent().appendingPathComponent("images")
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = document.deletingPathExtension().lastPathComponent + "-" + stamp.string(from: Date())
        var name = base + ".png"
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base)-\(n).png"
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent(name), options: .withoutOverwriting)
        } catch {
            NSSound.beep()
            return false
        }
        // On its own paragraph, so it shows as the picture.
        let text = storage.string as NSString
        let at = selectedRange()
        func char(_ i: Int) -> unichar? { i >= 0 && i < text.length ? text.character(at: i) : nil }
        let before = at.location == 0 || (char(at.location - 1) == 10 && char(at.location - 2) == 10) ? ""
            : char(at.location - 1) == 10 ? "\n" : "\n\n"
        let after = NSMaxRange(at) >= text.length || (char(NSMaxRange(at)) == 10 && char(NSMaxRange(at) + 1).map { $0 == 10 } ?? true) ? ""
            : char(NSMaxRange(at)) == 10 ? "\n" : "\n\n"
        let link = "![](images/\(name))"
        if replace(at, with: before + link + after) {
            setSelectedRange(NSRange(location: at.location + ((before + link) as NSString).length, length: 0))
        }
        return true
    }

    // MARK: Undo

    /// undo:/redo: travelling up the responder chain would reach the window,
    /// which uses its own undo manager. Answer them here, from this view's stack.
    /// Undo and redo work while reading too (a checkbox toggles while
    /// reading); the text view would otherwise refuse the change.
    @objc func undo(_ sender: Any?) {
        if let document = cellHost?.document { document.undo(sender); return }
        whileEditable { documentUndo.undo() }
    }
    @objc func redo(_ sender: Any?) {
        if let document = cellHost?.document { document.redo(sender); return }
        whileEditable { documentUndo.redo() }
    }

    private func whileEditable(_ body: () -> Void) {
        let was = isEditable
        isEditable = true
        body()
        isEditable = was
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case Selector(("undo:")): return (cellHost?.document?.documentUndo ?? documentUndo).canUndo
        case Selector(("redo:")): return (cellHost?.document?.documentUndo ?? documentUndo).canRedo
        default: return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: Return

    /// The kind of the top-level block the caret is in (nil between blocks).
    private func blockKindAtCaret() -> String? {
        let caret = selectedRange().location
        return layout.blocks.first { $0.range.location <= caret && caret <= NSMaxRange($0.range) }?.kind
    }

    /// Return in a paragraph or heading starts a new paragraph ("\n\n"):
    /// a single "\n" would be a Markdown soft break and reflow away.
    /// Elsewhere (code, lists, quotes, tables) it stays a plain newline.
    override func insertNewline(_ sender: Any?) {
        if let host = cellHost { host.move(from: self, .down); return }
        if continueListOrQuote() { return }
        guard isEditable, ["paragraph", "heading"].contains(blockKindAtCaret() ?? "") else {
            super.insertNewline(sender)
            return
        }
        let at = selectedRange()
        if replace(at, with: "\n\n") {
            setSelectedRange(NSRange(location: at.location + 2, length: 0))
        }
    }

    /// Shift-Return breaks the line within a paragraph: a Markdown hard
    /// break ("\\" + newline), not AppKit's invisible U+2028.
    override func insertLineBreak(_ sender: Any?) {
        if isCell { NSSound.beep(); return }   // a table cell is one line
        guard isEditable, ["paragraph", "heading"].contains(blockKindAtCaret() ?? "") else {
            super.insertNewline(sender)
            return
        }
        let at = selectedRange()
        if replace(at, with: "\\\n") {
            setSelectedRange(NSRange(location: at.location + 2, length: 0))
        }
    }

    /// AppKit's arrow-up from a line that starts with a hidden prefix ("# ")
    /// proposes that same line's start (the null glyphs sit at x = 0), and
    /// the caret rule then puts it back past the prefix: the caret never
    /// leaves the line. If it is still on the same visual line, go up one.
    override func moveUp(_ sender: Any?) {
        let before = selectedRange()
        super.moveUp(sender)
        guard let lm = layoutManager, selectedRange().length == 0, before.length == 0,
              let storage = textStorage, storage.length > 0 else { return }
        func lineTop(_ index: Int) -> CGFloat {
            let glyph = lm.glyphIndexForCharacter(at: min(index, storage.length - 1))
            return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        }
        let after = selectedRange().location
        guard after > 0, lineTop(after) == lineTop(before.location) else { return }
        let lineStart = (storage.string as NSString).lineRange(for: NSRange(location: after, length: 0)).location
        guard lineStart > 0 else { return }
        setSelectedRange(NSRange(location: lineStart - 1, length: 0))
    }

    override func cancelOperation(_ sender: Any?) {
        // NSTextView doesn't implement cancelOperation:; passing it to super throws.
        if revealing { reveal(false) }
    }

    // MARK: Table hover controls

    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !isCell else { return }
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    /// Over a table: show its controls for the cell under the pointer. Just
    /// outside it (where the controls sit) they stay; farther away they go.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !isCell else { return }
        let point = convert(event.locationInWindow, from: nil)
        for grid in tableGrids where !grid.isHidden {
            if grid.frame.contains(point) {
                grid.hover(at: convert(point, to: grid))
            } else if !grid.frame.insetBy(dx: -54, dy: -28).contains(point) {
                grid.hover(at: nil)
            }
        }
    }

    /// A table command (from the Table menu or a cell's context menu): acts
    /// on the cell being edited; anywhere else there is no table to act on.
    @objc func performTableCommand(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let command = TableCommand(rawValue: raw), let host = cellHost else { NSSound.beep(); return }
        host.perform(command, from: self)
    }

    @objc func toggleRevealMarkup(_ sender: Any?) {
        if let host = cellHost { host.revealSource(from: self) } else { reveal(!revealing) }
    }
    @objc func toggleShowMarkdown(_ sender: Any?) { toggleShowAllMarkup() }
    @objc func toggleBold(_ sender: Any?) { wrapSelection("**") }
    @objc func toggleItalic(_ sender: Any?) { wrapSelection("*") }

    func wrapSelection(_ marker: String) {
        guard isEditable, let storage = textStorage,
              let result = EditRules.toggleWrap(selectedRange(), marker: marker, in: storage.string as NSString)
        else { return }
        undoManager?.beginUndoGrouping()
        for patch in result.patches.reversed() {
            replace(NSRange(location: patch.from, length: patch.to - patch.from), with: patch.insert)
        }
        undoManager?.endUndoGrouping()
        setSelectedRange(result.selection)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let context = NSGraphicsContext.current?.cgContext {
            context.setAllowsFontSmoothing(true)
            context.setShouldSmoothFonts(fontSmoothing)
        }
        super.draw(dirtyRect)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let input = decorationInput(codePillRuns: codePillRuns()) else { return }
        DocumentDecorations.draw(input, in: rect)
    }

    /// What the shared decorations and geometry read, in view coordinates.
    private func decorationInput(codePillRuns: [MarkdownLayout.StyleRun] = []) -> DecorationInput? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return nil }
        return DecorationInput(
            layout: layout, theme: theme, storage: storage, layoutManager: lm, textContainer: tc,
            origin: textContainerOrigin,
            isRevealed: { [showAllMarkup, revealedUnits = engine.revealedUnits] in
                showAllMarkup || revealedUnits.contains($0)
            },
            isHidden: isHidden, images: imageStore, blockImageSize: imageSize(for:),
            inlineImageSize: engine.inlineImageSize, blockImagesInline: engine.treatsBlockImagesAsInline,
            diagramImage: { [weak self] in self?.diagramImage(for: $0) },
            codePillRuns: codePillRuns,
            pixelAlign: pixelAligned)
    }

    // MARK: Delegates

    /// Delegate object for the view and its text storage.
    private final class Hooks: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        weak var view: DocumentTextView?
        var loading = false

        func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                         range: NSRange, changeInLength delta: Int) {
            guard mask.contains(.editedCharacters), !loading else { return }
            view?.recordEdit(editedRange: range, delta: delta)
        }

        func textDidChange(_ notification: Notification) { view?.textChanged() }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view else { return }
            view.typingAttributes = view.theme.base
            view.selectionChanged()
            view.updateReviewFocus()
        }

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                      toCharacterRange new: NSRange) -> NSRange {
            guard let view, !view.showAllMarkup, new.length == 0 else { return new }
            return NSRange(location: view.caretStop(new.location, movingForward: new.location >= old.location), length: 0)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString string: String?) -> Bool {
            guard let view, !view.showAllMarkup, string == "", let storage = view.textStorage,
                  !view.applyingEdit, view.documentUndo.isUndoing == false, view.documentUndo.isRedoing == false
            else { return true }   // keystrokes only: not undo/redo, not the app's own edits
            let caret = view.selectedRange().location
            let action = view.pictureDelete(range, caret: caret).map(EditRules.DeleteAction.replace)
                ?? EditRules.retargetDelete(range, caret: caret, in: storage.string as NSString, isHidden: view.isHidden)
            switch action {
            case .allow:
                return true
            case .ignore:
                return false
            case .replace(let target):
                // Not re-entrantly: this runs inside the text view's own edit.
                DispatchQueue.main.async {
                    if view.replace(target, with: "") {
                        view.setSelectedRange(NSRange(location: target.location, length: 0))
                    }
                }
                return false
            }
        }

        func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range: NSRange) -> Int {
            view?.isSpellExempt(range) == true ? 0 : value
        }
    }
}
