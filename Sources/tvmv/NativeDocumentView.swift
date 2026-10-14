import TVMVCore
import SwiftUI
import AppKit

/// Imperative handle on a window's native text view: outline jumps,
/// bookmarks, reading position, find, and the markup commands.
@MainActor
final class NativeDocumentController {
    private(set) weak var textView: DocumentTextView?

    func attach(_ view: DocumentTextView) { textView = view }

    var window: NSWindow? { textView?.window }

    /// Scroll so the heading whose slug is `anchor` sits at the top.
    func scrollTo(anchor: String) {
        guard let view = textView else { return }
        var slugger = HeadingSlugger()
        for heading in view.layout.headings where slugger.slug(heading.title) == anchor {
            scrollTo(offset: heading.range.location)
            return
        }
    }

    /// UTF-16 offset of the first character at the top of the visible area.
    func topVisibleOffset() -> Int {
        guard let view = textView, let lm = view.layoutManager, let tc = view.textContainer,
              (view.string as NSString).length > 0 else { return 0 }
        // One point below the edge: exactly at it, the line above (whose
        // fragment includes its paragraph spacing) would claim the point.
        let point = NSPoint(x: 0, y: max(0, view.visibleRect.minY - view.textContainerOrigin.y + 1))
        return lm.characterIndexForGlyph(at: lm.glyphIndex(for: point, in: tc))
    }

    func scrollTo(offset: Int) {
        guard let view = textView, let lm = view.layoutManager, let tc = view.textContainer else { return }
        let length = (view.string as NSString).length
        guard length > 0 else { return }
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: min(max(0, offset), length - 1), length: 1),
                                   actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        view.scroll(NSPoint(x: 0, y: max(0, rect.minY + view.textContainerOrigin.y)))
    }

    func scrollTo(fraction: Double) {
        guard let view = textView, let clip = view.enclosingScrollView?.contentView, let tc = view.textContainer else { return }
        view.layoutManager?.ensureLayout(for: tc)
        let maxY = max(0, view.bounds.height - clip.bounds.height)
        view.scroll(NSPoint(x: 0, y: maxY * min(1, max(0, fraction))))
    }

    func restore(_ position: ReadingPositionStore.Position?) {
        switch position {
        case .offset(let offset): scrollTo(offset: offset)
        case .fraction(let fraction): scrollTo(fraction: fraction)
        case nil: break
        }
    }

    /// Scroll progress, 0...1.
    var progress: Double {
        guard let view = textView, let clip = view.enclosingScrollView?.contentView else { return 0 }
        let maxY = view.bounds.height - clip.bounds.height
        return maxY > 0 ? min(1, max(0, clip.bounds.minY / maxY)) : 0
    }

    func showFind() {
        guard let view = textView else { return }
        view.window?.makeFirstResponder(view)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(item)
    }

    func toggleRevealMarkup() { textView?.toggleRevealMarkup(nil) }
    func toggleShowMarkdown() { textView?.toggleShowMarkdown(nil) }
    func bold() { textView?.toggleBold(nil) }
    func italic() { textView?.toggleItalic(nil) }

    /// Follow a link from the document: `#slug` scrolls to that heading; a
    /// URL with a scheme opens externally; anything else is a path relative
    /// to the document's folder.
    func follow(_ link: String, documentURL: URL?) {
        if link.hasPrefix("#") {
            let anchor = String(link.dropFirst())
            scrollTo(anchor: anchor.removingPercentEncoding ?? anchor)
        } else if let url = URL(string: link), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else if let folder = documentURL?.deletingLastPathComponent() {
            let path = String(link.split(separator: "#", maxSplits: 1).first ?? "")
            NSWorkspace.shared.open(folder.appendingPathComponent(path.removingPercentEncoding ?? path))
        }
    }

    /// Outline entries for a layout, with the web reader's slugs.
    static func outline(from layout: MarkdownLayout) -> [OutlineItem] {
        var slugger = HeadingSlugger()
        return layout.headings.map { OutlineItem(level: $0.level, title: $0.title, anchor: slugger.slug($0.title)) }
    }
}

/// The macOS document surface: a scroll view hosting the native
/// reader/editor, wired to the window's `ViewerModel`.
struct NativeDocumentView: NSViewRepresentable {
    @ObservedObject var model: ViewerModel
    let controller: NativeDocumentController
    let theme: NativeTheme
    let isEditable: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A scroll view hosting a fresh text view.
    static func makeScrollView(theme: NativeTheme) -> (NSScrollView, DocumentTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = DocumentTextView.make()
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        // Exactly the clip view's size: under Auto Layout the autoresizing
        // mask becomes constraints, and any mismatch here would persist.
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        scroll.documentView = view
        view.theme = theme
        scroll.backgroundColor = theme.paper
        return (scroll, view)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = Self.makeScrollView(theme: theme)

        let model = self.model
        let controller = self.controller
        view.onEdit = { patch, length in model.editorTextPatched([patch], expectedLength: length) }
        view.onLayout = { layout in
            let outline = NativeDocumentController.outline(from: layout)
            if outline != model.outline { model.outline = outline }
        }
        view.onFollowLink = { [weak controller] link in controller?.follow(link, documentURL: model.fileURL) }
        view.load(model.text)
        controller.attach(view)

        // A file change adopted with no unsaved edits: replace the text, keep the place.
        model.onExternalTextAdopted = { [weak view, weak controller] text in
            guard let view, let controller else { return }
            let top = controller.topVisibleOffset()
            view.load(text)
            controller.scrollTo(offset: top)
        }

        context.coordinator.observeScrolling(scroll.contentView, model: model, controller: controller)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view, weak scroll] in
            guard let view, let scroll else { return }
            FileHandle.standardError.write(Data("DIAG scroll \(scroll.contentSize.width) view \(view.frame.width) inset \(view.textContainerInset.width) container \(view.textContainer!.size.width)\n".utf8))
        }
        DispatchQueue.main.async {
            controller.restore(model.nativeReadingPosition)
            context.coordinator.restored = true
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? DocumentTextView else { return }
        if view.theme != theme {
            view.theme = theme
            scroll.backgroundColor = theme.paper
        }
        if view.isEditable != isEditable {
            view.isEditable = isEditable
            if isEditable { view.window?.makeFirstResponder(view) }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// Saves the reading position as the user scrolls (debounced).
    @MainActor
    final class Coordinator {
        var restored = false
        private var observer: NSObjectProtocol?
        private var pending: Task<Void, Never>?

        func observeScrolling(_ clip: NSClipView, model: ViewerModel, controller: NativeDocumentController) {
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self, weak model, weak controller] _ in
                MainActor.assumeIsolated {
                    guard let self, self.restored, let model, let controller else { return }
                    self.pending?.cancel()
                    self.pending = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
                        model.nativeReadingChanged(offset: controller.topVisibleOffset(), progress: controller.progress)
                    }
                }
            }
        }

        func stop() {
            pending?.cancel()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
