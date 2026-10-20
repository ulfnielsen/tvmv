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
        // Keep the caret where it was, shifted past any patches before it.
        let shift = patches.filter { $0.to <= selection.location }
            .reduce(0) { $0 + ($1.insert as NSString).length - ($1.to - $1.from) }
        let location = min(max(0, selection.location + shift), (string as NSString).length)
        setSelectedRange(NSRange(location: location, length: 0))
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

    private static func gitUserName(in folder: URL?) -> String? {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = (folder.map { ["-C", $0.path] } ?? []) + ["config", "user.name"]
        let out = Pipe()
        git.standardOutput = out
        git.standardError = FileHandle.nullDevice
        guard (try? git.run()) != nil else { return nil }
        git.waitUntilExit()
        guard git.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
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

        if models != reviewModels || wide != reviewMarginIsWide {
            reviewCards.forEach { $0.removeFromSuperview() }
            reviewMarkers.forEach { $0.removeFromSuperview() }
            reviewCards = []
            reviewMarkers = []
            for model in models {
                if wide {
                    let card = makeCard(model)
                    addSubview(card)
                    reviewCards.append(card)
                } else {
                    let marker = ClosureButton(title: "") { [weak self] in self?.showCardPopover(model.id) }
                    marker.isBordered = false
                    marker.image = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: "Comment")
                    marker.contentTintColor = theme.accent
                    marker.toolTip = model.entries.first.map { "@\($0.author): \($0.body)" }
                    addSubview(marker)
                    reviewMarkers.append(marker)
                }
            }
            reviewModels = models
            reviewMarginIsWide = wide
            updateReviewFocus()
        }

        func lineTop(_ location: Int) -> CGFloat {
            guard storage.length > 0 else { return textContainerOrigin.y }
            let glyph = lm.glyphIndexForCharacter(at: min(location, storage.length - 1))
            return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerOrigin.y
        }
        var next = -CGFloat.greatestFiniteMagnitude
        for (card, model) in zip(reviewCards, models) {
            card.fit(width: cardWidth)
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
