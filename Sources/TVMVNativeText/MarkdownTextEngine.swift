import CoreGraphics
import Foundation
import TVMVCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// The text view an engine works for.
@MainActor
public protocol MarkdownTextHost: AnyObject {
    /// IME composition is in progress: no layout is applied until it ends.
    var hasMarkedText: Bool { get }
    /// `range` was restyled: lay it out and redraw.
    func engine(_ engine: MarkdownTextEngine, didRestyle range: NSRange)
    /// A new layout was applied and restyled (headings, images, tables may have changed).
    func engine(_ engine: MarkdownTextEngine, didApply layout: MarkdownLayout)
    /// A re-parse starts; `edit` is the range edited since `layout`, in the
    /// current text. Until the parse lands (later, in large documents), the
    /// host keeps that range laid out.
    func engine(_ engine: MarkdownTextEngine, willParse edit: NSRange)
    /// A re-parse's layout is in place and about to be restyled: revealed
    /// units can be re-found (their ranges moved with the edit).
    func engine(_ engine: MarkdownTextEngine, didInstall layout: MarkdownLayout)
}

public extension MarkdownTextHost {
    func engine(_ engine: MarkdownTextEngine, willParse edit: NSRange) {}
    func engine(_ engine: MarkdownTextEngine, didInstall layout: MarkdownLayout) {}
}

/// Parses a text storage's Markdown and styles it with its markup hidden.
///
/// - Parsing: after each edit the whole text is re-parsed (synchronously up
///   to `syncParseLimit`, otherwise off the main thread, latest wins), and
///   only the range where the old and new layouts differ is restyled.
/// - Reveal: the markup of `revealedUnits` (or all of it, with
///   `showAllMarkup`) is shown.
@MainActor
public final class MarkdownTextEngine {
    public static let syncParseLimit = 64 * 1024

    public let storage: NSTextStorage
    public private(set) weak var host: MarkdownTextHost?

    public private(set) var layout = MarkdownLayout()
    public var theme = NativeTheme(bodyFamily: "Georgia", monoFamily: "Menlo", size: 16,
                                   measure: 80, fullWidth: false, dark: false)
    public var showAllMarkup = false {
        didSet { restyle(NSRange(location: 0, length: storage.length)) }
    }
    public private(set) var revealedUnits: [NSRange] = []
    /// The height a loaded block image is drawn at (nil: a text line).
    public var blockImageHeight: (MarkdownLayout.BlockImage) -> CGFloat? = { _ in nil }
    /// The height a table's grid reserves, by index in `layout.tables`.
    public var tableHeight: (Int) -> CGFloat? = { _ in nil }
    /// The size a loaded inline image is drawn at (nil: its alt shows).
    public var inlineImageSize: (MarkdownLayout.InlineImage) -> CGSize? = { _ in nil }
    /// The height a rendered diagram is drawn at (nil: its source shows).
    public var diagramHeight: (MarkdownLayout.Diagram) -> CGFloat? = { _ in nil }
    /// Block images are styled as inline images (a table cell is one line).
    public var treatsBlockImagesAsInline = false

    private var parseGeneration = 0
    /// Background parses started (observability for large-document typing).
    public private(set) var backgroundParsesStarted = 0
    /// At most one background parse runs; edits meanwhile queue one more
    /// parse of whatever the text is when it finishes.
    private var parseInFlight = false
    private var parseQueued = false
    /// Characters at the start and end of the text unchanged since `layout` was computed.
    private var unchangedPrefix = Int.max
    private var unchangedSuffix = Int.max

    public init(storage: NSTextStorage, host: MarkdownTextHost) {
        self.storage = storage
        self.host = host
    }

    // MARK: Content

    /// Replace the whole text (initial load, external reload).
    public func load(_ text: String) {
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        parseGeneration += 1   // a parse still in flight was for the old text
        layout = MarkdownLayoutParser.parse(text)
        unchangedPrefix = .max; unchangedSuffix = .max
        restyle(NSRange(location: 0, length: storage.length))
        host?.engine(self, didApply: layout)
    }

    // MARK: Parse + restyle

    /// Note a character edit (from the storage delegate): `editedRange` in
    /// the new text, `delta` the change in length.
    public func recordEdit(editedRange: NSRange, delta: Int) {
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        let oldLength = storage.length - delta
        unchangedPrefix = min(unchangedPrefix, oldRange.location)
        unchangedSuffix = min(unchangedSuffix, oldLength - NSMaxRange(oldRange))
    }

    /// Re-parse after edits (outside the storage's processEditing).
    public func textChanged() {
        guard host?.hasMarkedText != true else { return }
        let text = storage.string
        let old = layout
        let prefix = min(unchangedPrefix, old.length), suffix = min(unchangedSuffix, old.length - prefix)
        let edit = NSRange(location: prefix, length: old.length - suffix - prefix)
        let delta = storage.length - old.length
        // Offsets before the edit are valid in the old layout.
        host?.engine(self, willParse: NSRange(location: edit.location, length: max(0, edit.length + delta)))
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

    /// Bring `layout` up to date with the text now (a table cell edit needs
    /// the table's current cell ranges, which a pending background parse may not have).
    public func ensureCurrentLayout() {
        guard layout.length != storage.length || unchangedPrefix != .max || parseInFlight else { return }
        parseGeneration += 1
        applyParsed(MarkdownLayoutParser.parse(storage.string), from: layout,
                    edit: NSRange(location: 0, length: layout.length), delta: storage.length - layout.length,
                    generation: parseGeneration)
    }

    /// Install a parse result unless a newer edit has superseded it (latest wins).
    private func applyParsed(_ new: MarkdownLayout, from old: MarkdownLayout, edit: NSRange, delta: Int, generation: Int) {
        // Only a layout of exactly the current text may be applied: edits
        // during IME composition don't bump the generation, and applying a
        // layout of other text would hide the wrong characters.
        guard generation == parseGeneration, host?.hasMarkedText != true,
              new.length == storage.length else { return }
        unchangedPrefix = .max; unchangedSuffix = .max
        let changed = new.changedRange(from: old, edit: edit, delta: delta)
        layout = new
        host?.engine(self, didInstall: new)
        restyle(changed)
        host?.engine(self, didApply: new)
    }

    public func restyle(_ range: NSRange) {
        let units = revealedUnits
        let all = showAllMarkup
        DocumentStyler.apply(layout, to: storage, in: range, theme: theme,
                             isRevealed: { all || units.contains($0) },
                             imageHeight: blockImageHeight, tableHeight: tableHeight,
                             inlineImageSize: inlineImageSize, blockImagesInline: treatsBlockImagesAsInline,
                             diagramHeight: diagramHeight)
        host?.engine(self, didRestyle: range)
    }

    // MARK: Reveal

    public func isRevealed(_ unit: NSRange) -> Bool { showAllMarkup || revealedUnits.contains(unit) }

    /// Units containing `selection`. A caret at a unit's end counts as
    /// inside it — unless the unit ends with a newline (a block): then the
    /// caret is already on the next line.
    public func units(enclosing selection: NSRange) -> [NSRange] {
        let text = storage.string as NSString
        return layout.revealUnits.filter { unit in
            guard unit.encloses(selection) else { return false }
            if selection.length == 0, selection.location == NSMaxRange(unit), unit.length > 0,
               text.character(at: NSMaxRange(unit) - 1) == 10 { return false }
            return true
        }
    }

    /// Show the markup of `units` (and hide the rest), restyling what changed.
    public func setRevealedUnits(_ units: [NSRange]) {
        guard units != revealedUnits else { return }
        let touched = (units + revealedUnits).reduce(nil as NSRange?) { acc, r in acc.map { NSUnionRange($0, r) } ?? r }
        revealedUnits = units
        if let touched { restyle(touched) }
    }
}
