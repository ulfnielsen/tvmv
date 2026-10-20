import AppKit
import TVMVCore

/// Review actions: each one is a set of `ReviewMarkup` patches applied as a
/// single undoable edit through the view's edit path, allowed while reading
/// too (commenting doesn't need edit mode).
extension DocumentTextView {
    enum Settlement { case resolve, accept, reject }

    /// The review markup of the text as it is now (the layout's copy may lag
    /// behind a background parse).
    var currentReview: ReviewMarkup.Review { ReviewMarkup.parse(string) }

    private var selectionRange: Range<Int> {
        let selection = selectedRange()
        return selection.location..<NSMaxRange(selection)
    }

    /// Comment on the selection (a point comment for a caret). Returns the
    /// new thread's id, or nil when the selection can't hold one.
    @discardableResult
    func addComment(body: String, author: String, date: Date = Date(), timeZone: TimeZone = .current) -> String? {
        let review = currentReview
        let id = ReviewMarkup.newID(existing: review.ids)
        let patches = review.addComment(range: selectionRange, body: body, author: author,
                                        date: date, timeZone: timeZone, id: id)
        return applyReview(patches) ? id : nil
    }

    /// Suggest `replacement` for the selection (an insertion at a caret, a
    /// deletion when empty). Returns the new thread's id.
    @discardableResult
    func addSuggestion(replacement: String, body: String, author: String,
                       date: Date = Date(), timeZone: TimeZone = .current) -> String? {
        let review = currentReview
        let id = ReviewMarkup.newID(existing: review.ids)
        let patches = review.addSuggestion(range: selectionRange, replacement: replacement, body: body,
                                           author: author, date: date, timeZone: timeZone, id: id)
        return applyReview(patches) ? id : nil
    }

    @discardableResult
    func reply(to id: String, body: String, author: String, date: Date = Date(), timeZone: TimeZone = .current) -> Bool {
        applyReview(currentReview.reply(id: id, body: body, author: author, date: date, timeZone: timeZone))
    }

    @discardableResult
    func settle(_ id: String, _ how: Settlement) -> Bool {
        let review = currentReview
        switch how {
        case .resolve: return applyReview(review.resolve(id: id))
        case .accept: return applyReview(review.accept(id: id))
        case .reject: return applyReview(review.reject(id: id))
        }
    }

    @discardableResult
    func settleAll(accepting: Bool) -> Bool {
        let review = currentReview
        return applyReview(accepting ? review.acceptAll() : review.rejectAll())
    }

    /// Where a caret at `location` belongs after `patches`: shifted past the
    /// ones before it, and at the end of one it was inside. A new thread
    /// definition never carries it along: at the end of the text that would
    /// leave the caret behind the hidden thread.
    static func caret(_ location: Int, through patches: [TextPatcher.Patch]) -> Int {
        var shift = 0
        for patch in patches {
            let length = (patch.insert as NSString).length
            if patch.to <= location {
                if patch.from == location, patch.insert.contains("]: @") { continue }
                shift += length - (patch.to - patch.from)
            } else if patch.from < location {
                return patch.from + shift + length
            }
        }
        return max(0, location + shift)
    }

    /// Apply `patches` (ascending, non-overlapping) as one undoable edit.
    /// False — and nothing written — when there are none.
    @discardableResult
    func applyReview(_ patches: [TextPatcher.Patch]) -> Bool {
        guard !patches.isEmpty else { return false }
        let wasEditable = isEditable
        isEditable = true
        defer { isEditable = wasEditable }
        let selection = selectedRange()
        undoManager?.beginUndoGrouping()
        for patch in patches.reversed() {
            replace(NSRange(location: patch.from, length: patch.to - patch.from), with: patch.insert)
        }
        undoManager?.endUndoGrouping()
        setSelectedRange(NSRange(location: Self.caret(selection.location, through: patches), length: 0))
        return true
    }
}

/// Who a review entry is by: "@" plus the first word of git's user.name,
/// lowercased; without git, the account's short name.
enum ReviewAuthor {
    static func handle(gitName: String?, account: String) -> String {
        let first = gitName?.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return (first ?? account).lowercased()
    }

    /// The handle for documents in `folder`, read once per folder.
    @MainActor static func current(for folder: URL?) -> String {
        let key = folder?.path ?? ""
        if let cached = cache[key] { return cached }
        let handle = handle(gitName: gitUserName(in: folder), account: NSUserName())
        cache[key] = handle
        return handle
    }

    @MainActor private static var cache: [String: String] = [:]

    /// git's user.name for `folder`: its repository's config, then the global
    /// ones. Read from the files, not by running git: without the developer
    /// tools, /usr/bin/git only offers to install them.
    static func gitUserName(in folder: URL?,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        var configs: [URL] = []
        var directory = folder?.standardizedFileURL
        while let current = directory {
            let dotGit = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { configs.append(dotGit.appendingPathComponent("config")) }
                break
            }
            let parent = current.deletingLastPathComponent()
            directory = parent.path == current.path ? nil : parent
        }
        configs += [home.appendingPathComponent(".gitconfig"), home.appendingPathComponent(".config/git/config")]
        for config in configs {
            if let text = try? String(contentsOf: config, encoding: .utf8), let name = userName(inConfig: text) {
                return name
            }
        }
        return nil
    }

    /// `name` in the `[user]` section of a git config file.
    static func userName(inConfig text: String) -> String? {
        var inUser = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inUser = line.lowercased().hasPrefix("[user]")
                continue
            }
            guard inUser, let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "name" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), let close = value.dropFirst().firstIndex(of: "\"") {
                value = String(value[value.index(after: value.startIndex)..<close])
            } else if let comment = value.firstIndex(where: { $0 == ";" || $0 == "#" }) {
                value = value[..<comment].trimmingCharacters(in: .whitespaces)
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

// MARK: Margin

extension DocumentTextView {
    /// Cards narrower than this become markers.
    static let minimumCardWidth: CGFloat = 180

    /// Place a card (or, in a narrow margin, a marker) beside each thread's
    /// anchor, stacked top to bottom without overlapping.
    func layoutReviewMargin() {
        guard !isCell, !layingOutReview, let lm = layoutManager, let tc = textContainer, let storage = textStorage
        else { return }
        layingOutReview = true
        defer { layingOutReview = false }
        let models = layout.review.map(ReviewCards.models) ?? []
        let columnRight = textContainerOrigin.x + tc.size.width
        let cardX = columnRight + 28
        let cardWidth = min(300, bounds.width - cardX - 20)
        let wide = cardWidth >= Self.minimumCardWidth

        // Keep every card (and marker) whose content is unchanged: an edit
        // moves anchors on every keystroke, and a rebuild would cost a layout
        // pass per card and lose a reply being written.
        let reuse = wide == reviewMarginIsWide && theme == reviewTheme
        if wide {
            var existing = reuse ? Dictionary(reviewCards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
            var cards: [ReviewCardView] = []
            for model in models {
                if let card = existing.removeValue(forKey: model.id), card.model.showsSame(as: model) {
                    card.model = model
                    cards.append(card)
                } else {
                    let card = makeCard(model)
                    addSubview(card)
                    cards.append(card)
                }
            }
            for card in reviewCards where !cards.contains(where: { $0 === card }) { card.removeFromSuperview() }
            reviewCards = cards
            reviewMarkers.forEach { $0.removeFromSuperview() }
            reviewMarkers = []
        } else {
            let same = reuse && models.count == reviewModels.count
                && zip(models, reviewModels).allSatisfy { $0.showsSame(as: $1) }
            if !same {
                reviewMarkers.forEach { $0.removeFromSuperview() }
                reviewMarkers = models.map { model in
                    let marker = ClosureButton(title: "") { [weak self] in self?.showCardPopover(model.id) }
                    marker.isBordered = false
                    marker.image = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: "Comment")
                    marker.contentTintColor = theme.accent
                    marker.toolTip = model.entries.first.map { "@\($0.author): \($0.body)" }
                    addSubview(marker)
                    return marker
                }
            }
            reviewCards.forEach { $0.removeFromSuperview() }
            reviewCards = []
        }
        let changed = models != reviewModels
        reviewModels = models
        reviewMarginIsWide = wide
        reviewTheme = theme
        if changed { updateReviewFocus() }

        func lineTop(_ location: Int) -> CGFloat {
            guard storage.length > 0 else { return textContainerOrigin.y }
            let glyph = lm.glyphIndexForCharacter(at: min(location, storage.length - 1))
            return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerOrigin.y
        }
        var next = -CGFloat.greatestFiniteMagnitude
        for (card, model) in zip(reviewCards, models) {
            if card.fittedWidth != cardWidth { card.fit(width: cardWidth) }
            let y = max(lineTop(model.anchor), next)
            card.setFrameOrigin(NSPoint(x: cardX, y: y))
            next = card.frame.maxY + 8
        }
        for (marker, model) in zip(reviewMarkers, models) {
            let size = NSSize(width: 20, height: 18)
            let y = max(lineTop(model.anchor) + 4, next)
            marker.frame = NSRect(origin: NSPoint(x: columnRight + 10, y: y), size: size)
            next = marker.frame.maxY + 4
        }
        // The view grows to hold a card that reaches past the text.
        let bottom = max(next, 0) + textContainerInset.height
        if minSize.height != bottom, bottom > 0 { minSize.height = bottom; sizeToFit() }
    }

    private func makeCard(_ model: ReviewCards.Model) -> ReviewCardView {
        let card = ReviewCardView(model: model, theme: theme)
        card.onAction = { [weak self] action in self?.perform(action, on: model.id) }
        return card
    }

    private func perform(_ action: ReviewCardView.Action, on id: String) {
        switch action {
        case .accept: settle(id, .accept)
        case .reject, .removeMarkup: settle(id, .reject)
        case .resolve, .deleteThread: settle(id, .resolve)
        case .reply(let body):
            reply(to: id, body: body, author: ReviewAuthor.current(for: documentURL?.deletingLastPathComponent()))
        }
        reviewPopover?.close()
    }

    func showCardPopover(_ id: String) {
        guard let model = reviewModels.first(where: { $0.id == id }),
              let index = reviewModels.firstIndex(of: model), index < reviewMarkers.count else { return }
        let card = makeCard(model)
        card.fit(width: 300)
        let controller = NSViewController()
        controller.view = card
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.contentSize = card.frame.size
        reviewPopover?.close()
        reviewPopover = popover
        popover.show(relativeTo: reviewMarkers[index].bounds, of: reviewMarkers[index], preferredEdge: .maxX)
    }

    /// Focus the card of the anchor the caret is in (none outside anchors).
    func updateReviewFocus() {
        guard let storage = textStorage, !reviewCards.isEmpty else { return }
        let caret = selectedRange().location
        var id: String?
        for location in [caret, caret - 1] where location >= 0 && location < storage.length {
            if let found = storage.attribute(.tvmvReview, at: location, effectiveRange: nil) as? String { id = found; break }
        }
        for card in reviewCards { card.isFocused = card.id == id }
    }
}

// MARK: Commands

extension DocumentTextView {
    @objc func addReviewComment(_ sender: Any?) { openComposer(suggestion: false) }
    @objc func suggestReviewEdit(_ sender: Any?) { openComposer(suggestion: true) }
    @objc func nextReviewThread(_ sender: Any?) { moveToThread(forward: true) }
    @objc func previousReviewThread(_ sender: Any?) { moveToThread(forward: false) }
    @objc func acceptAllSuggestions(_ sender: Any?) { if !settleAll(accepting: true) { NSSound.beep() } }
    @objc func rejectAllSuggestions(_ sender: Any?) { if !settleAll(accepting: false) { NSSound.beep() } }

    private var author: String { ReviewAuthor.current(for: documentURL?.deletingLastPathComponent()) }

    private func openComposer(suggestion: Bool) {
        // A table cell has its own selection, in its own text: commenting on
        // a cell isn't supported yet, and the main text's selection is stale.
        if isCell || (window?.firstResponder as? DocumentTextView)?.isCell == true {
            NSSound.beep()
            return
        }
        let selection = selectedRange()
        let composer = ReviewComposerView(
            suggestion: suggestion ? (string as NSString).substring(with: selection) : nil)
        // The selection is an offset into the text as it is now: if the text
        // changes while the composer is open, it would land on other words.
        let original = string
        composer.onSubmit = { [weak self] body, replacement in
            guard let self else { return nil }
            guard self.string == original else {
                return "The document changed. Close this and select the text again."
            }
            self.setSelectedRange(selection)
            let id = replacement.map {
                self.addSuggestion(replacement: $0, body: body, author: self.author)
            } ?? self.addComment(body: body, author: self.author)
            guard id != nil else { return "Select text within one paragraph, outside code and other comments." }
            self.reviewComposerPopover?.close()
            return nil
        }
        composer.onCancel = { [weak self] in self?.reviewComposerPopover?.close() }
        let controller = NSViewController()
        controller.view = composer
        let popover = NSPopover()
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = composer.frame.size
        popover.behavior = .transient
        reviewComposerPopover?.close()
        reviewComposer = composer
        reviewComposerPopover = popover
        popover.show(relativeTo: selectionRect(selection), of: self, preferredEdge: .maxY)
        window?.makeFirstResponder(composer.replacementField ?? composer.bodyField)
    }

    /// Where the selection is drawn, in view coordinates (its first line).
    private func selectionRect(_ selection: NSRange) -> NSRect {
        guard let lm = layoutManager, let tc = textContainer else { return bounds }
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: selection.location, length: max(1, selection.length)),
                                   actualCharacterRange: nil)
        var line = NSRange()
        lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &line)
        let rect = lm.boundingRect(forGlyphRange: NSIntersectionRange(glyphs, line).length > 0
                                   ? NSIntersectionRange(glyphs, line) : glyphs, in: tc)
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Put the caret at the next (previous) thread's anchor, wrapping around.
    private func moveToThread(forward: Bool) {
        // The text as it is now: in a large document the layout's copy can
        // lag behind a background parse.
        let anchors = ReviewCards.models(currentReview)
            .filter { $0.kind != .orphanThread }.map(\.anchor)
        guard !anchors.isEmpty else { NSSound.beep(); return }
        let caret = selectedRange().location
        let target = forward
            ? anchors.first { $0 > caret } ?? anchors[0]
            : anchors.last { $0 < caret } ?? anchors[anchors.count - 1]
        setSelectedRange(NSRange(location: target, length: 0))
        scrollRangeToVisible(NSRange(location: target, length: 0))
    }
}
