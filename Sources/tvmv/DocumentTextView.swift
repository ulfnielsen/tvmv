import AppKit
import ImageIO
import TVMVCore

/// The native reader/editor: one TextKit 1 text view in which Markdown
/// renders in place with its markup hidden.
///
/// - Hiding: markers carry `.tvmvHidden`; the layout-manager delegate turns
///   those characters into null glyphs. The text itself never changes.
/// - Parsing: after each edit the whole text is re-parsed (synchronously up
///   to `syncParseLimit`, otherwise off the main thread, latest wins), and
///   only the range where the old and new layouts differ is restyled.
/// - Reveal: double-click or ⌘' shows the markup of the span(s) under the
///   selection until Esc or the selection leaves them; ⌥⌘M shows all markup.
final class DocumentTextView: NSTextView {
    static let syncParseLimit = 64 * 1024

    private(set) var layout = MarkdownLayout()
    var theme: NativeTheme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16,
                                         measure: 80, fullWidth: false, dark: false) {
        didSet { applyTheme() }
    }
    var showAllMarkup = false {
        didSet { restyle(NSRange(location: 0, length: textStorage?.length ?? 0)) }
    }
    /// Draw with AppKit font smoothing (stroke thickening). Off, as in the
    /// web reader (-webkit-font-smoothing: antialiased).
    var fontSmoothing = false {
        didSet { needsDisplay = true }
    }
        /// True after a reveal request, until the selection leaves every revealed unit.
    private(set) var revealing = false
    private var revealedUnits: [NSRange] = []

    /// Every text change, as a patch against the previous text plus the new length.
    var onEdit: ((TextPatcher.Patch, Int) -> Void)?
    /// A new layout was applied (headings may have changed).
    var onLayout: ((MarkdownLayout) -> Void)?
    /// A link was activated (read-only click, or ⌘-click while editing).
    var onFollowLink: ((String) -> Void)?
    /// Called once, the first time the view gets a non-zero width.
    var onSized: (() -> Void)?
    /// The document's file: relative image paths resolve against its folder.
    var documentURL: URL?
    /// Set on a table cell's editor: the grid it belongs to.
    weak var cellHost: TableGridView?
    var isCell: Bool { cellHost != nil }
    /// One grid per table in `layout.tables`, in order.
    private(set) var tableGrids: [TableGridView] = []
    private var tableHeights: [Int: CGFloat] = [:]
    private var layingOutGrids = false
    /// A cell's edits wait here until its edit has finished processing.
    private var pendingCellPatches: [TextPatcher.Patch] = []

    override var isEditable: Bool {
        didSet { if !isCell { tableGrids.forEach { $0.setEditable(isEditable) } } }
    }

    enum ImageState: Equatable { case loading, loaded, failed }
    /// Block images by their address as written, loaded once and cached.
    private var images: [String: (state: ImageState, image: NSImage?)] = [:]

    func imageState(for address: String) -> ImageState? { images[address]?.state }
    /// A document is untrusted: cap what one image may cost.
    var maxImageBytes = 50_000_000
    var maxImagePixels = 100_000_000

    /// Private undo stack: the window's document undo manager belongs to a
    /// DocumentGroup(viewing:) document that can't be saved, and registering
    /// edits there triggers autosave alerts (see CodeMirrorEditorPane's history).
    private(set) var documentUndo = UndoManager()
    override var undoManager: UndoManager? { documentUndo }

    private let hooks = Hooks()
    private var parseGeneration = 0
    /// Background parses started (observability for large-document typing).
    private(set) var backgroundParsesStarted = 0
    /// At most one background parse runs; edits meanwhile queue one more
    /// parse of whatever the text is when it finishes.
    private var parseInFlight = false
    private var parseQueued = false
    /// Characters at the start and end of the text unchanged since `layout` was computed.
    private var unchangedPrefix = Int.max
    private var unchangedSuffix = Int.max

    static func make() -> DocumentTextView {
        let view = DocumentTextView(usingTextLayoutManager: false)   // TextKit 1: null glyphs
        view.configure()
        return view
    }

    private func configure() {
        hooks.view = self
        delegate = hooks
        layoutManager?.delegate = hooks
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
        guard let storage = textStorage else { return }
        hooks.loading = true
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        hooks.loading = false
        documentUndo.removeAllActions()
        parseGeneration += 1   // a parse still in flight was for the old text
        layout = MarkdownLayoutParser.parse(text)
        unchangedPrefix = .max; unchangedSuffix = .max
        pendingCellPatches = []
        restyle(NSRange(location: 0, length: storage.length))
        requestImages()
        onLayout?(layout)
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
        let oldLength = storage.length - delta
        unchangedPrefix = min(unchangedPrefix, oldRange.location)
        unchangedSuffix = min(unchangedSuffix, oldLength - NSMaxRange(oldRange))
        let insert = (storage.string as NSString).substring(with: editedRange)
        let patch = TextPatcher.Patch(from: oldRange.location, to: NSMaxRange(oldRange), insert: insert)
        if isCell { pendingCellPatches.append(patch) }
        onEdit?(patch, storage.length)
    }

    /// Re-parse after edits (called from textDidChange, outside processEditing).
    fileprivate func textChanged() {
        guard let storage = textStorage, !hasMarkedText() else { return }
        if let host = cellHost, !pendingCellPatches.isEmpty {
            let patches = pendingCellPatches
            pendingCellPatches = []
            patches.forEach { host.cellDidEdit(self, $0) }
        }
        let text = storage.string
        let old = layout
        let prefix = min(unchangedPrefix, old.length), suffix = min(unchangedSuffix, old.length - prefix)
        let edit = NSRange(location: prefix, length: old.length - suffix - prefix)
        let delta = storage.length - old.length
        // Until the parse lands (later, in large documents), keep the edited
        // paragraph laid out from its start. Offsets before the edit are valid
        // in the old layout.
        relayParagraphs(touching: NSRange(location: edit.location, length: max(0, edit.length + delta)))
        parseGeneration += 1
        let generation = parseGeneration
        if storage.length <= Self.syncParseLimit {
            applyParsed(MarkdownLayoutParser.parse(text), from: old, edit: edit, delta: delta, generation: generation)
        } else {
            guard !parseInFlight else { parseQueued = true; return }
            parseInFlight = true
            backgroundParsesStarted += 1
            Task {
                let new = await Task.detached(priority: .userInitiated) { MarkdownLayoutParser.parse(text) }.value
                self.parseInFlight = false
                self.applyParsed(new, from: old, edit: edit, delta: delta, generation: generation)
                if self.parseQueued {
                    self.parseQueued = false
                    self.textChanged()
                }
            }
        }
    }

    /// Install a parse result unless a newer edit has superseded it (latest wins).
    private func applyParsed(_ new: MarkdownLayout, from old: MarkdownLayout, edit: NSRange, delta: Int, generation: Int) {
        // Only a layout of exactly the current text may be applied: edits
        // during IME composition don't bump the generation, and applying a
        // layout of other text would hide the wrong characters.
        guard generation == parseGeneration, !hasMarkedText(),
              new.length == textStorage?.length else { return }
        unchangedPrefix = .max; unchangedSuffix = .max
        let changed = new.changedRange(from: old, edit: edit, delta: delta)
        layout = new
        updateRevealedUnits()
        restyle(changed)
        requestImages()
        onLayout?(new)
    }

    /// Composition can end without a text change (no textDidChange), so
    /// re-parse here too.
    override func unmarkText() {
        super.unmarkText()
        textChanged()
    }

    func restyle(_ range: NSRange) {
        guard let storage = textStorage else { return }
        let units = revealedUnits
        let all = showAllMarkup
        let heights = tableHeights
        DocumentStyler.apply(layout, to: storage, in: range, theme: theme,
                             isRevealed: { all || units.contains($0) },
                             imageHeight: { [weak self] in self?.imageSize(for: $0)?.height },
                             tableHeight: { heights[$0] })
        // TextKit re-lays out an edit from the line after the previous
        // newline, assuming a newline ends a line. In a reflowed paragraph a
        // soft break doesn't, so re-lay the whole paragraph from its start.
        relayParagraphs(touching: range)
        layoutGrids()
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
        restyle(NSRange(location: 0, length: textStorage?.length ?? 0))
    }

    /// Center a column of `theme.columnWidth` (or fill the width) with at least `theme.padding` each side.
    func layoutColumn() {
        guard let container = textContainer else { return }
        if isCell {   // a table cell fills its frame, inside its own inset
            container.containerSize = NSSize(width: max(1, bounds.width - 2 * textContainerInset.width),
                                             height: .greatestFiniteMagnitude)
            return
        }
        let available = max(200, bounds.width - 2 * theme.padding)
        let width = min(theme.columnWidth ?? available, available)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textContainerInset = NSSize(width: max(theme.padding, (bounds.width - width) / 2), height: 36)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let column = textContainer?.size.width
        super.setFrameSize(newSize)
        layoutColumn()
        if textContainer?.size.width != column {   // images and tables scale with the column
            restyleImages { _ in true }
            layoutGrids()
        }
        if newSize.width > 0, let sized = onSized {
            onSized = nil
            sized()
        }
    }

    // MARK: Reveal

    /// Show the markup of the unit(s) enclosing the selection (on), or hide it again (off).
    func reveal(_ on: Bool) {
        setRevealedUnits(on ? unitsEnclosingSelection() : [])
    }

    /// Reveal one unit and put the caret at its start (a table revealed from
    /// one of its cells: its source is hidden until revealed, so the caret
    /// could not be placed in it first).
    func reveal(unit: NSRange) {
        setRevealedUnits([unit])
        setSelectedRange(NSRange(location: unit.location, length: 0))
    }

    func toggleShowAllMarkup() { showAllMarkup.toggle() }

    /// Units containing the selection. A caret at a unit's end counts as
    /// inside it — unless the unit ends with a newline (a block): then the
    /// caret is already on the next line.
    func unitsEnclosingSelection() -> [NSRange] {
        guard let storage = textStorage else { return [] }
        let text = storage.string as NSString
        let selection = selectedRange()
        return layout.revealUnits.filter { unit in
            guard unit.encloses(selection) else { return false }
            if selection.length == 0, selection.location == NSMaxRange(unit), unit.length > 0,
               text.character(at: NSMaxRange(unit) - 1) == 10 { return false }
            return true
        }
    }

    private func setRevealedUnits(_ units: [NSRange]) {
        revealing = !units.isEmpty
        guard units != revealedUnits else { return }
        let touched = (units + revealedUnits).reduce(nil as NSRange?) { acc, r in acc.map { NSUnionRange($0, r) } ?? r }
        revealedUnits = units
        if let touched { restyle(touched) }
    }

    /// Selection moved: a reveal ends once the selection leaves every revealed unit.
    fileprivate func selectionChanged() {
        guard revealing else { return }
        let current = Set(unitsEnclosingSelection())
        if !revealedUnits.contains(where: current.contains) { setRevealedUnits([]) }
    }

    /// After a re-parse, revealed units are re-found around the selection
    /// (their ranges moved with the edit).
    fileprivate func updateRevealedUnits() {
        if revealing { setRevealedUnits(unitsEnclosingSelection()) }
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

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
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

    /// Where a list item's text starts on screen (its line fragment and the
    /// x of the text), or nil if not laid out.
    private func listItemGeometry(_ item: MarkdownLayout.ListItem) -> (fragment: NSRect, baseline: CGFloat, textX: CGFloat)? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage,
              NSMaxRange(item.marker) <= storage.length else { return nil }
        let content = min(NSMaxRange(item.marker), max(0, storage.length - 1))
        let glyph = lm.glyphIndexForCharacter(at: content)
        let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let style = storage.attribute(.paragraphStyle, at: content, effectiveRange: nil) as? NSParagraphStyle
        let textX = textContainerOrigin.x + tc.lineFragmentPadding + (style?.firstLineHeadIndent ?? 0)
        let baseline = fragment.minY + textContainerOrigin.y + lm.location(forGlyphAt: glyph).y
        return (fragment, baseline, textX)
    }

    /// The clickable checkbox of a task item, in view coordinates.
    func taskBoxRect(for item: MarkdownLayout.ListItem) -> NSRect? {
        guard item.task != nil, let g = listItemGeometry(item) else { return nil }
        let side = theme.body.pointSize * 0.8
        return NSRect(x: g.textX - side - theme.body.pointSize * 0.45, y: g.baseline - side * 0.95, width: side, height: side)
    }

    /// The task item whose checkbox is at `point` (with a little slack), if any.
    func taskItem(at point: NSPoint) -> Int? {
        layout.listItems.indices.first { i in
            !(showAllMarkup || revealedUnits.contains(layout.listItems[i].marker))
                && taskBoxRect(for: layout.listItems[i])?.insetBy(dx: -4, dy: -4).contains(point) == true
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

    /// Bullets, numbers, checkboxes and quote rules, in the indent the styler left.
    private func drawListsAndQuotes(visible: NSRange) {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return }
        let em = theme.body.pointSize
        for quote in layout.quoteLines where NSLocationInRange(quote.prefix.location, visible)
            && NSMaxRange(quote.prefix) <= storage.length && !(showAllMarkup || revealedUnits.contains(quote.prefix)) {
            let at = min(NSMaxRange(quote.prefix), max(0, storage.length - 1))
            let fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: at), effectiveRange: nil)
            theme.muted.withAlphaComponent(0.45).setFill()
            for k in 0..<quote.level {
                NSRect(x: textContainerOrigin.x + tc.lineFragmentPadding + CGFloat(k) * 1.2 * em + 0.2 * em,
                       y: fragment.minY + textContainerOrigin.y, width: 3, height: fragment.height).fill()
            }
        }
        for item in layout.listItems where NSLocationInRange(item.marker.location, visible)
            && !(showAllMarkup || revealedUnits.contains(item.marker)) {
            guard let g = listItemGeometry(item) else { continue }
            if let task = item.task, let box = taskBoxRect(for: item) {
                let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
                if task {
                    theme.accent.setFill(); path.fill()
                    let check = NSBezierPath()
                    check.move(to: NSPoint(x: box.minX + box.width * 0.22, y: box.midY))
                    check.line(to: NSPoint(x: box.minX + box.width * 0.42, y: box.maxY - box.height * 0.25))
                    check.line(to: NSPoint(x: box.maxX - box.width * 0.2, y: box.minY + box.height * 0.25))
                    check.lineWidth = 1.6
                    theme.paper.setStroke(); check.stroke()
                } else {
                    path.lineWidth = 1.2
                    theme.muted.setStroke(); path.stroke()
                }
                continue
            }
            let label: String
            if item.ordered {
                label = (storage.string as NSString).substring(with: item.bullet)
            } else {
                label = ["•", "◦", "▪"][min(item.level, 2)]
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: theme.body, .foregroundColor: theme.muted]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: NSPoint(x: g.textX - size.width - 0.45 * em, y: g.baseline - theme.body.ascender),
                                     withAttributes: attributes)
        }
    }

    // MARK: Tables

    /// Inline code runs that get a pill: not those in a table's hidden
    /// source (its grid draws the cells).
    func codePillRuns() -> [MarkdownLayout.StyleRun] {
        let hiddenTables = layout.tables.map(\.range).filter { !(showAllMarkup || revealedUnits.contains($0)) }
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
    func layoutGrids() {
        guard !isCell, !layingOutGrids, let storage = textStorage, let lm = layoutManager, let tc = textContainer
        else { return }
        layingOutGrids = true
        defer { layingOutGrids = false }
        while tableGrids.count > layout.tables.count { tableGrids.removeLast().removeFromSuperview() }
        while tableGrids.count < layout.tables.count {
            let grid = TableGridView(document: self)
            addSubview(grid)
            tableGrids.append(grid)
        }
        let width = tc.size.width - 2 * tc.lineFragmentPadding
        for (i, table) in layout.tables.enumerated() where NSMaxRange(table.range) <= storage.length {
            let grid = tableGrids[i]
            grid.index = i
            grid.isHidden = showAllMarkup || revealedUnits.contains(table.range)
            guard !grid.isHidden else { continue }
            grid.update(table: table, text: storage.string as NSString, width: width, theme: theme, editable: isEditable)
            if tableHeights[i] != grid.frame.height {
                tableHeights[i] = grid.frame.height
                let heights = tableHeights, units = revealedUnits, all = showAllMarkup
                DocumentStyler.apply(layout, to: storage, in: table.range, theme: theme,
                                     isRevealed: { all || units.contains($0) },
                                     imageHeight: { [weak self] in self?.imageSize(for: $0)?.height },
                                     tableHeight: { heights[$0] })
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

    /// Bring `layout` up to date with the text now (a cell edit needs the
    /// table's current cell ranges, which a pending background parse may not have).
    private func ensureCurrentLayout() {
        guard let storage = textStorage, layout.length != storage.length || unchangedPrefix != .max || parseInFlight
        else { return }
        parseGeneration += 1
        applyParsed(MarkdownLayoutParser.parse(storage.string), from: layout,
                    edit: NSRange(location: 0, length: layout.length), delta: storage.length - layout.length,
                    generation: parseGeneration)
    }

    /// A cell's own edit, applied to that cell's source.
    func applyCellEdit(table index: Int, row: Int, column: Int, _ patch: TextPatcher.Patch) {
        ensureCurrentLayout()
        guard index < layout.tables.count, row < layout.tables[index].rows.count,
              column < layout.tables[index].rows[row].count else { return }
        let source = TableSource.cellEdit(layout.tables[index], row: row, column: column, patch)
        replace(NSRange(location: source.from, length: source.to - source.from), with: source.insert)
    }

    /// A structural change: the table is rewritten neatly.
    func reformatTable(_ index: Int, _ change: (inout [[String]], inout [MarkdownLayout.Table.Alignment]) -> Void) {
        ensureCurrentLayout()
        guard isEditable, index < layout.tables.count, let storage = textStorage else { return }
        let patch = TableSource.reformat(layout.tables[index], in: storage.string as NSString, change)
        replace(NSRange(location: patch.from, length: patch.to - patch.from), with: patch.insert)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if let host = cellHost { host.menuItems(for: self).forEach { menu?.addItem($0) } }
        return menu
    }

    override func insertTab(_ sender: Any?) {
        if let host = cellHost { host.move(from: self, .next) } else { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if let host = cellHost { host.move(from: self, .previous) } else { super.insertBacktab(sender) }
    }

    // MARK: Images

    /// Where an image address points. Like the web reader, local images come
    /// only from inside the document's folder (no "../", absolute paths or
    /// file URLs); http, https and data URLs load as written.
    static func imageURL(_ address: String, documentURL: URL?) -> URL? {
        if let url = URL(string: address), let scheme = url.scheme?.lowercased() {
            return ["http", "https", "data"].contains(scheme) ? url : nil
        }
        let path = address.removingPercentEncoding ?? address
        guard !path.hasPrefix("/"), let folder = documentURL?.deletingLastPathComponent().standardizedFileURL
        else { return nil }
        let candidate = folder.appendingPathComponent(path).standardizedFileURL
        return isInside(candidate, folder) ? candidate : nil
    }

    nonisolated static func isInside(_ candidate: URL, _ folder: URL) -> Bool {
        let base = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return candidate.path.hasPrefix(base)
    }

    /// Read a local image: a regular file, still inside the folder once
    /// symlinks are resolved, and no larger than `limit`.
    nonisolated static func readLocal(_ url: URL, folder: URL, limit: Int) -> Data? {
        let real = url.resolvingSymlinksInPath()
        guard isInside(real, folder.resolvingSymlinksInPath()),
              let values = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= limit
        else { return nil }
        return try? Data(contentsOf: real)
    }

    /// Download at most `limit` bytes; nil if there is more.
    nonisolated static func download(_ url: URL, limit: Int) async -> Data? {
        guard let (bytes, response) = try? await URLSession.shared.bytes(from: url),
              response.expectedContentLength <= Int64(limit) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
        } catch { return nil }
        return data
    }

    /// Decode within `maxImagePixels`, failing closed:
    /// - a raster image must report dimensions for every frame, and all its
    ///   frames together must fit the limit (NSImage loads them all);
    /// - an image ImageIO can't measure loads only if it is purely vector
    ///   (SVG, PDF) and its declared size fits the same limit;
    /// - anything else is refused.
    private func decode(_ data: Data) -> NSImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
           CGImageSourceGetType(source) != nil {
            var total = 0
            for index in 0..<CGImageSourceGetCount(source) {
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int
                else { return nil }
                let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
                guard !overflow else { return nil }
                total += pixels
                if total > maxImagePixels { return nil }
            }
            return NSImage(data: data)
        }
        guard let picture = NSImage(data: data), !picture.representations.isEmpty,
              picture.representations.allSatisfy({ !($0 is NSBitmapImageRep) }),
              picture.size.width * picture.size.height <= CGFloat(maxImagePixels)
        else { return nil }
        return picture
    }

    /// The size a loaded block image is drawn at: its own size, scaled down
    /// (never up) to the text column.
    private func imageSize(for image: MarkdownLayout.BlockImage) -> NSSize? {
        guard let picture = images[image.url]?.image, picture.size.width > 0, let container = textContainer else { return nil }
        let column = container.size.width - 2 * container.lineFragmentPadding
        let width = min(picture.size.width, column)
        return NSSize(width: width, height: picture.size.height * width / picture.size.width)
    }

    /// Start loading every block image not yet requested.
    private func requestImages() {
        for image in layout.blockImages where images[image.url] == nil {
            let address = image.url
            images[address] = (.loading, nil)
            guard let url = Self.imageURL(address, documentURL: documentURL) else {
                imageLoaded(address, data: nil)
                continue
            }
            let limit = maxImageBytes
            let folder = documentURL?.deletingLastPathComponent().standardizedFileURL
            Task {
                let data: Data?
                switch url.scheme?.lowercased() {
                case "http", "https":
                    data = await Self.download(url, limit: limit)
                case "data":
                    data = (try? Data(contentsOf: url)).flatMap { $0.count <= limit ? $0 : nil }
                default:
                    data = await Task.detached(priority: .utility) {
                        folder.flatMap { Self.readLocal(url, folder: $0, limit: limit) }
                    }.value
                }
                self.imageLoaded(address, data: data)
            }
        }
    }

    private func imageLoaded(_ address: String, data: Data?) {
        let picture = data.flatMap(decode)
        images[address] = (picture == nil ? .failed : .loaded, picture)
        restyleImages { $0.url == address }
    }

    private func restyleImages(where match: (MarkdownLayout.BlockImage) -> Bool) {
        for image in layout.blockImages where match(image) { restyle(image.range) }
    }

    /// Draw each shown block image into the line its hidden source reserves;
    /// a failed one shows its alt text instead.
    private func drawImages(visible: NSRange) {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return }
        for image in layout.blockImages
        where NSIntersectionRange(image.range, visible).length > 0 && NSMaxRange(image.range) <= storage.length
            && !(showAllMarkup || revealedUnits.contains(image.range)) {
            let fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: image.range.location),
                                               effectiveRange: nil)
            let x = fragment.minX + tc.lineFragmentPadding + textContainerOrigin.x
            if let size = imageSize(for: image), let picture = images[image.url]?.image {
                let rect = NSRect(x: x, y: fragment.minY + textContainerOrigin.y + theme.body.pointSize / 2,
                                  width: size.width, height: size.height)
                picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                             respectFlipped: true, hints: nil)
            } else if images[image.url]?.state == .failed {
                let label = image.alt.isEmpty ? image.url : image.alt
                let font = NSFontManager.shared.convert(theme.body, toHaveTrait: .italicFontMask)
                let y = fragment.minY + textContainerOrigin.y + (fragment.height - font.boundingRectForFont.height) / 2
                ("▨ " + label as NSString).draw(at: NSPoint(x: x, y: y),
                                                withAttributes: [.font: font, .foregroundColor: theme.muted])
            }
        }
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
        if revealing { reveal(false) } else { super.cancelOperation(sender) }
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
        guard let lm = layoutManager, let tc = textContainer else { return }
        let visible = lm.characterRange(
            forGlyphRange: lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y), in: tc),
            actualGlyphRange: nil)
        theme.paperDeep.setFill()
        for block in layout.codeBlocks where NSIntersectionRange(block.range, visible).length > 0 && block.body.length > 0 {
            let glyphs = lm.glyphRange(forCharacterRange: block.body, actualCharacterRange: nil)
            var box = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            box.origin.x = textContainerOrigin.x - 12
            box.size.width = tc.containerSize.width + 24
            box.origin.y += textContainerOrigin.y - 8
            box.size.height += 16
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        }
        // Inline code: a pill hugging the code font around its baseline, per line.
        let pad = theme.mono.pointSize * 0.14
        for run in codePillRuns() where NSIntersectionRange(run.range, visible).length > 0 {
            let glyphs = lm.glyphRange(forCharacterRange: run.range, actualCharacterRange: nil)
            var g = glyphs.location
            while g < NSMaxRange(glyphs) {
                var lineGlyphs = NSRange()
                let fragment = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &lineGlyphs)
                let part = NSIntersectionRange(glyphs, lineGlyphs)
                guard part.length > 0 else { break }
                let extent = lm.boundingRect(forGlyphRange: part, in: tc)
                let baseline = fragment.minY + lm.location(forGlyphAt: part.location).y
                let pill = NSRect(x: extent.minX - 2 + textContainerOrigin.x,
                                  y: baseline - theme.mono.ascender - pad + textContainerOrigin.y,
                                  width: extent.width + 4,
                                  height: theme.mono.ascender - theme.mono.descender + 2 * pad)
                NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
                g = NSMaxRange(part)
            }
        }
        drawImages(visible: visible)
        drawListsAndQuotes(visible: visible)
    }

    // MARK: Delegates

    /// Delegate object for the view, its layout manager and its text storage.
    private final class Hooks: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate, NSTextStorageDelegate {
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
        }

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                      toCharacterRange new: NSRange) -> NSRange {
            guard let view, !view.showAllMarkup, new.length == 0, let storage = view.textStorage else { return new }
            let location = EditRules.snapCaret(new.location, movingForward: new.location >= old.location,
                                               in: storage.string as NSString, isHidden: view.isHidden)
            return NSRange(location: location, length: 0)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString string: String?) -> Bool {
            guard let view, !view.showAllMarkup, string == "", let storage = view.textStorage,
                  !view.applyingEdit, view.documentUndo.isUndoing == false, view.documentUndo.isRedoing == false
            else { return true }   // keystrokes only: not undo/redo, not the app's own edits
            let caret = view.selectedRange().location
            switch EditRules.retargetDelete(range, caret: caret, in: storage.string as NSString, isHidden: view.isHidden) {
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

        /// Soft line breaks lay out as spaces: the paragraph reflows.
        func layoutManager(_ lm: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                           forControlCharacterAt index: Int) -> NSLayoutManager.ControlCharacterAction {
            lm.textStorage?.attribute(.tvmvSoftBreak, at: index, effectiveRange: nil) != nil ? .whitespace : action
        }

        /// A whitespace-action control glyph is zero-wide unless sized here:
        /// a soft break takes the width of a space, or words run together.
        func layoutManager(_ lm: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                           for textContainer: NSTextContainer, proposedLineFragment: NSRect,
                           glyphPosition: NSPoint, characterIndex: Int) -> NSRect {
            let font = lm.textStorage?.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont
                ?? .systemFont(ofSize: NSFont.systemFontSize)
            let width = (" " as NSString).size(withAttributes: [.font: font]).width
            return NSRect(x: glyphPosition.x, y: 0, width: width, height: proposedLineFragment.height)
        }

        func layoutManager(_ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                           properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                           characterIndexes: UnsafePointer<Int>, font: NSFont,
                           forGlyphRange glyphRange: NSRange) -> Int {
            guard let storage = lm.textStorage else { return 0 }
            var props = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
            var changed = false
            var run = NSRange(location: NSNotFound, length: 0)
            var runHidden = false
            for i in 0..<glyphRange.length {
                let ci = characterIndexes[i]
                if !NSLocationInRange(ci, run) {
                    runHidden = storage.attribute(.tvmvHidden, at: ci, effectiveRange: &run) != nil
                }
                if runHidden, !props[i].contains(.controlCharacter) {
                    props[i] = .null
                    changed = true
                }
            }
            guard changed else { return 0 }
            lm.setGlyphs(glyphs, properties: props, characterIndexes: characterIndexes, font: font,
                         forGlyphRange: glyphRange)
            return glyphRange.length
        }
    }
}
