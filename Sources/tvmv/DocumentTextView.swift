import AppKit
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

    /// Private undo stack: the window's document undo manager belongs to a
    /// DocumentGroup(viewing:) document that can't be saved, and registering
    /// edits there triggers autosave alerts (see CodeMirrorEditorPane's history).
    private let documentUndo = UndoManager()
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
        restyle(NSRange(location: 0, length: storage.length))
        onLayout?(layout)
    }

    /// Replace `range` through the undoable edit path.
    @discardableResult
    func replace(_ range: NSRange, with string: String) -> Bool {
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
        onEdit?(.init(from: oldRange.location, to: NSMaxRange(oldRange), insert: insert), storage.length)
    }

    /// Re-parse after edits (called from textDidChange, outside processEditing).
    fileprivate func textChanged() {
        guard let storage = textStorage, !hasMarkedText() else { return }
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
        DocumentStyler.apply(layout, to: storage, in: range, theme: theme) { unit in
            all || units.contains(unit)
        }
        // TextKit re-lays out an edit from the line after the previous
        // newline, assuming a newline ends a line. In a reflowed paragraph a
        // soft break doesn't, so re-lay the whole paragraph from its start.
        relayParagraphs(touching: range)
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
        let available = max(200, bounds.width - 2 * theme.padding)
        let width = min(theme.columnWidth ?? available, available)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textContainerInset = NSSize(width: max(theme.padding, (bounds.width - width) / 2), height: 36)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutColumn()
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

    // MARK: Undo

    /// undo:/redo: travelling up the responder chain would reach the window,
    /// which uses its own undo manager. Answer them here, from this view's stack.
    @objc func undo(_ sender: Any?) { documentUndo.undo() }
    @objc func redo(_ sender: Any?) { documentUndo.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case Selector(("undo:")): return documentUndo.canUndo
        case Selector(("redo:")): return documentUndo.canRedo
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

    @objc func toggleRevealMarkup(_ sender: Any?) { reveal(!revealing) }
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
        for run in layout.styles where run.style == .code && NSIntersectionRange(run.range, visible).length > 0 {
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
            guard let view, !view.showAllMarkup, string == "", let storage = view.textStorage else { return true }
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
