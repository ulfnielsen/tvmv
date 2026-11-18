import AppKit
import os
import TVMVNativeText

/// AppKit's Find bar searches one ordered stream, but the visible text of a
/// rendered table lives in independent text views. Each cell is a search
/// boundary, with offsets mapped back through its hidden inline markup.
@MainActor
final class DocumentFindClient: NSObject, @preconcurrency NSTextFinderClient {
    private struct Segment {
        unowned let view: DocumentTextView
        let range: NSRange
        let text: String
        let source: NSRange
        // Nil for identity mappings; otherwise one UTF-16 offset per character.
        let offsets: [Int]?

        func localRange(_ match: NSRange) -> NSRange {
            let start = match.location - range.location
            guard let offsets else { return NSRange(location: source.location + start, length: match.length) }
            let from = start < offsets.count ? offsets[start] : source.upperBound
            let to = match.length > 0 ? offsets[start + match.length - 1] + 1 : from
            return NSRange(location: from, length: to - from)
        }

        func searchOffset(_ local: Int) -> Int {
            guard let offsets else { return range.location + local - source.location }
            return range.location + (offsets.firstIndex { $0 >= local } ?? offsets.count)
        }
    }

    private weak var document: DocumentTextView?
    private weak var matchView: DocumentTextView?
    private var matchSelection: NSRange?
    private weak var actionView: DocumentTextView?
    private var cached: [Segment]?
    // AppKit's incremental search reads the string on a background queue.
    private nonisolated let snapshot = OSAllocatedUnfairLock(initialState: "")
    private static let boundary = "\u{FFFC}"
    private let finder = NSTextFinder()

    init(document: DocumentTextView) {
        self.document = document
        super.init()
        finder.isIncrementalSearchingEnabled = true
    }

    func invalidate() {
        guard cached != nil else { return }
        finder.noteClientStringWillChange()
        cached = nil
        DispatchQueue.main.async { [weak self] in _ = self?.segments }
    }

    func detach() {
        finder.noteClientStringWillChange()
        finder.cancelFindIndicator()
        finder.client = nil
        finder.findBarContainer = nil
    }

    func perform(_ action: NSTextFinder.Action, from view: DocumentTextView) {
        finder.client = self
        finder.findBarContainer = document?.enclosingScrollView
        _ = segments
        actionView = view
        defer { actionView = nil }
        finder.performAction(action)
    }

    func validate(_ action: NSTextFinder.Action) -> Bool {
        finder.client = self
        finder.findBarContainer = document?.enclosingScrollView
        return finder.validateAction(action)
    }

    private var segments: [Segment] {
        if let cached { return cached }
        guard let document, let storage = document.textStorage else { return [] }
        var result: [Segment] = []
        var index = 0
        func append(_ view: DocumentTextView, _ text: String, _ source: NSRange, offsets: [Int]? = nil) {
            let length = text.utf16.count
            guard length > 0 else { return }
            if !result.isEmpty { index += 1 } // one UTF-16 unit for the boundary
            result.append(Segment(view: view, range: NSRange(location: index, length: length),
                                  text: text, source: source, offsets: offsets))
            index += length
        }
        let raw = storage.string as NSString
        func appendBody(from start: Int, to end: Int) {
            guard end > start else { return }
            let range = NSRange(location: start, length: end - start)
            append(document, raw.substring(with: range), range)
        }
        var start = 0
        for (table, grid) in zip(document.layout.tables, document.tableGrids)
            where !grid.isHidden && table.range.location >= start && table.range.upperBound <= raw.length {
            appendBody(from: start, to: table.range.location)
            for cell in grid.cells.joined() {
                guard let storage = cell.textStorage, storage.length > 0 else { continue }
                let source = NSRange(location: 0, length: storage.length)
                let rawCell = storage.string as NSString
                var visible = ""
                var offsets: [Int] = []
                storage.enumerateAttribute(.tvmvHidden, in: source) { hidden, range, _ in
                    guard hidden == nil else { return }
                    visible += rawCell.substring(with: range)
                    offsets.append(contentsOf: range.location..<range.upperBound)
                }
                append(cell, visible, source, offsets: offsets.count == source.length ? nil : offsets)
            }
            start = table.range.upperBound
        }
        appendBody(from: start, to: raw.length)
        cached = result
        let searchable = result.map(\.text).joined(separator: Self.boundary)
        snapshot.withLock { $0 = searchable }
        return result
    }

    private func segment(at index: Int) -> Segment? {
        let segments = segments
        var low = 0, high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].range.upperBound <= index { low = mid + 1 } else { high = mid }
        }
        return low < segments.count && index >= segments[low].range.location ? segments[low] : nil
    }

    private func segment(containing range: NSRange) -> Segment? {
        guard let segment = segment(at: range.location), range.upperBound <= segment.range.upperBound else { return nil }
        return segment
    }

    nonisolated var string: String { snapshot.withLock { $0 } }

    var isSelectable: Bool { document?.isSelectable == true }
    var isEditable: Bool { document?.isEditable == true }
    var allowsMultipleSelection: Bool { false }

    var firstSelectedRange: NSRange {
        let focused = actionView ?? (document?.window?.firstResponder as? DocumentTextView)
        let target: DocumentTextView?
        if let focused, focused.cellHost?.document === document, focused !== matchView,
           focused !== document, focused.selectedRange().length > 0 {
            target = focused
        } else if let matchView, matchView.selectedRange() == matchSelection,
                  !matchView.isHiddenOrHasHiddenAncestor {
            target = matchView
        } else {
            target = focused?.cellHost?.document === document ? focused : document
        }
        guard let target else { return NSRange(location: 0, length: 0) }
        let selection = target.selectedRange()
        var anchor = 0
        for segment in segments where segment.view === target {
            if selection.location < segment.source.location { return NSRange(location: segment.range.location, length: 0) }
            anchor = segment.range.upperBound
            if selection.location <= segment.source.upperBound {
                let start = segment.searchOffset(selection.location)
                let end = segment.searchOffset(min(selection.upperBound, segment.source.upperBound))
                return NSRange(location: start, length: end - start)
            }
        }
        return NSRange(location: anchor, length: 0)
    }

    var selectedRanges: [NSValue] {
        get { [NSValue(range: firstSelectedRange)] }
        set {
            guard let range = newValue.first?.rangeValue, let segment = segment(containing: range) else { return }
            if let previous = matchView, previous !== segment.view, previous.selectedRange() == matchSelection {
                previous.setSelectedRange(NSRange(location: previous.selectedRange().upperBound, length: 0))
            }
            let local = segment.localRange(range)
            segment.view.setSelectedRange(local)
            matchView = segment.view
            matchSelection = local
        }
    }

    func contentView(at index: Int, effectiveCharacterRange range: NSRangePointer) -> NSView {
        if let segment = segment(at: index) {
            range.pointee = segment.range
            return segment.view
        }
        range.pointee = NSRange(location: 0, length: 0)
        return document ?? NSView()
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard range.length > 0, let segment = segment(containing: range),
              let manager = segment.view.layoutManager, let container = segment.view.textContainer else { return nil }
        let local = segment.localRange(range)
        manager.ensureLayout(forCharacterRange: local)
        var count = 0
        let rects = manager.rectArray(forCharacterRange: local, withinSelectedCharacterRange: NSRange(location: NSNotFound, length: 0),
                                     in: container, rectCount: &count)
        let origin = segment.view.textContainerOrigin
        guard let rects, count > 0 else { return nil }
        return (0..<count).map { NSValue(rect: rects[$0].offsetBy(dx: origin.x, dy: origin.y)) }
    }

    var visibleCharacterRanges: [NSValue] {
        segments.compactMap { segment in
            let view = segment.view
            guard !view.visibleRect.isEmpty else { return nil }
            if view !== document { return NSValue(range: segment.range) }
            guard let manager = view.layoutManager, let container = view.textContainer else { return nil }
            let origin = view.textContainerOrigin
            let glyphs = manager.glyphRange(forBoundingRect: view.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
            let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let local = NSIntersectionRange(visible, segment.source)
            guard local.length > 0 else { return nil }
            return NSValue(range: NSRange(location: segment.searchOffset(local.location), length: local.length))
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let segment = segment(containing: range) else { return }
        if segment.view === document {
            segment.view.scrollRangeToVisible(segment.localRange(range))
        } else if let rect = rects(forCharacterRange: range)?.first?.rectValue {
            segment.view.scrollToVisible(rect)
        }
    }

    func shouldReplaceCharacters(inRanges ranges: [NSValue], with strings: [String]) -> Bool {
        isEditable && zip(ranges, strings).allSatisfy { value, string in
            guard let segment = segment(containing: value.rangeValue) else { return false }
            // A match spanning hidden markers is searchable, but replacing it
            // would leave unbalanced Markdown. Edit that match in the cell.
            return segment.view === document || (segment.localRange(value.rangeValue).length == value.rangeValue.length
                && string.rangeOfCharacter(from: .newlines) == nil)
        }
    }

    func replaceCharacters(in range: NSRange, with string: String) {
        guard let segment = segment(containing: range) else { return }
        segment.view.replace(segment.localRange(range), with: string)
    }
}
