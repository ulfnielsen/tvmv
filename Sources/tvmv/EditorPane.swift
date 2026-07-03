import SwiftUI
import AppKit

/// A captured editor location, used to restore cursor + scroll when the
/// editor pane is closed and reopened (the NSTextView itself is destroyed
/// with the pane; the position outlives it in ViewerModel).
struct EditorPosition {
    var cursorOffset: Int   // UTF-16, clamped on restore
    var topLine: Int        // 1-based
}

/// Imperative surface for the editor pane, mirroring MarkdownWebController.
/// All offsets are UTF-16 (NSTextView's native unit); lines are 1-based
/// (cmark sourcepos's unit). LineIndex converts between them.
@MainActor
final class EditorController {
    weak var textView: NSTextView?

    /// 1-based line containing the insertion point.
    var cursorLine: Int {
        guard let tv = textView else { return 1 }
        return LineIndex.line(at: tv.selectedRange().location, in: tv.string)
    }

    /// 1-based line at the top of the visible rect.
    func topVisibleLine() -> Int {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else {
            return 1
        }
        let topPoint = CGPoint(x: 0, y: tv.visibleRect.minY)
        let glyph = lm.glyphIndex(for: topPoint, in: tc)
        let char = lm.characterIndexForGlyph(at: glyph)
        return LineIndex.line(at: char, in: tv.string)
    }

    /// Scroll so `line` sits near the top of the pane; optionally move the
    /// insertion point to its start.
    func scrollToLine(_ line: Int, placeCursor: Bool) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else {
            return
        }
        let offset = LineIndex.offset(ofLine: line, in: tv.string)
        let range = NSRange(location: offset, length: 0)
        if placeCursor { tv.setSelectedRange(range) }
        // Ensure layout exists for the target before asking for its rect.
        lm.ensureLayout(forCharacterRange: range)
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        tv.scroll(CGPoint(x: 0, y: max(0, rect.minY - 8)))
    }

    func capturePosition() -> EditorPosition {
        EditorPosition(
            cursorOffset: textView?.selectedRange().location ?? 0,
            topLine: topVisibleLine()
        )
    }

    func restore(_ p: EditorPosition) {
        guard let tv = textView else { return }
        let clamped = min(p.cursorOffset, (tv.string as NSString).length)
        tv.setSelectedRange(NSRange(location: clamped, length: 0))
        scrollToLine(p.topLine, placeCursor: false)
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }
}

/// Plain-text Markdown editor: an NSTextView in an NSScrollView. Text flows
/// out through `onTextChange` (the model owns the string); text flows back in
/// via `updateNSView` only when it differs (external reload), so the editor's
/// own keystrokes never reset cursor or scroll.
struct EditorPane: NSViewRepresentable {
    var text: String
    var onTextChange: (String) -> Void
    var onCursorMove: () -> Void
    var onScroll: () -> Void
    var onMakeController: (EditorController) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.string = text

        let controller = EditorController()
        controller.textView = tv
        context.coordinator.controller = controller
        onMakeController(controller)

        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorPane
        var controller: EditorController?

        init(_ parent: EditorPane) { self.parent = parent }

        deinit { NotificationCenter.default.removeObserver(self) }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.onTextChange(tv.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            parent.onCursorMove()
        }

        @objc func boundsChanged(_ note: Notification) {
            MainActor.assumeIsolated { parent.onScroll() }
        }
    }
}
