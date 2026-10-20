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

// MARK: Side column

extension DocumentTextView {
    /// The comment column right of the text: a gap, the cards, a margin.
    static let reviewGap: CGFloat = 24
    static let reviewCardWidth: CGFloat = 280
    static let reviewRightMargin: CGFloat = 20
    static var reviewColumnWidth: CGFloat { reviewGap + reviewCardWidth + reviewRightMargin }

    /// Room the text column leaves on its right: the comment column while the
    /// document has threads or one is being written, else none.
    var reviewColumnReserve: CGFloat { showsReviewColumn ? Self.reviewColumnWidth : 0 }

    /// Lay the comment column out: a card beside each thread's anchor (and
    /// the composer beside its selection), stacked without overlapping. The
    /// text column narrows to make room when the column appears.
    func layoutReviewMargin() {
        guard !isCell, !layingOutReview, let lm = layoutManager, let tc = textContainer, let storage = textStorage
        else { return }
        layingOutReview = true
        defer { layingOutReview = false }
        let models = layout.review.map(ReviewCards.models) ?? []

        let shows = !models.isEmpty || reviewComposer != nil
        if shows != showsReviewColumn {
            showsReviewColumn = shows
            columnChanged()
        }

        // Keep every card whose content is unchanged: an edit moves anchors on
        // every keystroke, and a rebuild would cost a layout pass per card and
        // lose a reply being written.
        var existing = theme == reviewTheme
            ? Dictionary(reviewCards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
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
        let changed = models != reviewModels
        reviewModels = models
        reviewTheme = theme
        if changed { updateReviewFocus() }

        let x = textContainerOrigin.x + tc.size.width + Self.reviewGap
        let width = max(200, min(Self.reviewCardWidth + 20, bounds.width - x - Self.reviewRightMargin))
        func lineTop(_ location: Int) -> CGFloat {
            guard storage.length > 0 else { return textContainerOrigin.y }
            let glyph = lm.glyphIndexForCharacter(at: min(max(0, location), storage.length - 1))
            return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerOrigin.y
        }
        // Cards and the composer, in anchor order.
        var items: [(anchor: Int, view: NSView)] = zip(models, cards).map { ($0.anchor, $1) }
        if let composer = reviewComposer { items.append((composer.anchor, composer)) }
        items.sort { $0.anchor < $1.anchor }
        for item in items {
            if let card = item.view as? ReviewCardView, card.fittedWidth != width { card.fit(width: width) }
            if let composer = item.view as? ReviewComposerView, composer.frame.width != width { composer.fit(width: width) }
        }
        let tops = Self.stack(items.map { (lineTop($0.anchor), $0.view.frame.height) },
                              pinned: items.firstIndex { $0.view === reviewComposer }
                                ?? items.firstIndex { ($0.view as? ReviewCardView)?.isFocused == true },
                              gap: 8, top: textContainerOrigin.y)
        for (item, y) in zip(items, tops) { item.view.setFrameOrigin(NSPoint(x: x, y: y)) }
        // The view grows to hold a card that reaches past the text (enforced
        // in setFrameSize: the scroll view resets minSize as it tiles).
        let next = zip(items, tops).map { $1 + $0.view.frame.height }.max()
        let bottom = next.map { $0 + textContainerInset.height } ?? 0
        if bottom != reviewMinHeight {
            let grew = bottom > reviewMinHeight
            reviewMinHeight = bottom
            // sizeToFit measures the text alone and skips a size it already
            // has, so a growing column sets the height itself.
            if grew, frame.height < bottom {
                setFrameSize(NSSize(width: frame.width, height: bottom))
            } else if !grew {
                sizeToFit()
            }
        }
    }

    /// Tops for items wanting to sit at `wanted` (each with its height),
    /// without overlapping: the pinned one (the focused card, the composer)
    /// exactly at its line, those after it pushed down, those before it
    /// pushed up — and all of them down again if that runs past `top`.
    static func stack(_ items: [(wanted: CGFloat, height: CGFloat)], pinned: Int?, gap: CGFloat, top: CGFloat) -> [CGFloat] {
        guard !items.isEmpty else { return [] }
        var tops = items.map(\.wanted)
        let p = pinned ?? 0
        for i in (p + 1)..<max(p + 1, items.count) {
            tops[i] = max(items[i].wanted, tops[i - 1] + items[i - 1].height + gap)
        }
        if p > 0 {
            for i in stride(from: p - 1, through: 0, by: -1) {
                tops[i] = min(items[i].wanted, tops[i + 1] - gap - items[i].height)
            }
        }
        if let first = tops.first, first < top {
            // Out of room above: push the whole stack down.
            let shift = top - first
            tops[0] += shift
            for i in 1..<tops.count { tops[i] = max(tops[i], tops[i - 1] + items[i - 1].height + gap) }
        }
        return tops
    }

    private func makeCard(_ model: ReviewCards.Model) -> ReviewCardView {
        let card = ReviewCardView(model: model, theme: theme)
        card.onAction = { [weak self] action in self?.perform(action, on: model.id) }
        card.onFocus = { [weak self] in self?.focusCard(model.id) }
        return card
    }

    /// Focus a card from a click on it: it shows its actions and moves to its line.
    func focusCard(_ id: String) {
        focusedReviewID = id
        for card in reviewCards { card.isFocused = card.id == id }
        layoutReviewMargin()
        revealFocusedCard()
    }

    /// A focused card grows by its actions; near the bottom of the window
    /// that would be out of sight, so scroll just enough to show it.
    private func revealFocusedCard() {
        guard let card = reviewCards.first(where: \.isFocused) else { return }
        scrollToVisible(card.frame)
    }

    private func perform(_ action: ReviewCardView.Action, on id: String) {
        switch action {
        case .accept: settle(id, .accept)
        case .reject, .removeMarkup: settle(id, .reject)
        case .resolve, .deleteThread: settle(id, .resolve)
        case .reply(let body):
            reply(to: id, body: body, author: ReviewAuthor.current(for: documentURL?.deletingLastPathComponent()))
        }
    }

    /// Focus the card of the anchor the caret is in (none outside anchors).
    func updateReviewFocus() {
        guard let storage = textStorage, !reviewCards.isEmpty else { return }
        let caret = selectedRange().location
        var id: String?
        for location in [caret, caret - 1] where location >= 0 && location < storage.length {
            if let found = storage.attribute(.tvmvReview, at: location, effectiveRange: nil) as? String { id = found; break }
        }
        focusedReviewID = id
        let before = reviewCards.map(\.isFocused)
        for card in reviewCards { card.isFocused = card.id == id }
        if reviewCards.map(\.isFocused) != before {
            layoutReviewMargin()
            revealFocusedCard()
        }
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

    /// Write a comment or suggestion in a card in the side column, beside
    /// the selection.
    private func openComposer(suggestion: Bool) {
        // A table cell has its own selection, in its own text: commenting on
        // a cell isn't supported yet, and the main text's selection is stale.
        if isCell || (window?.firstResponder as? DocumentTextView)?.isCell == true {
            NSSound.beep()
            return
        }
        closeComposer()
        let selection = selectedRange()
        let composer = ReviewComposerView(
            suggestion: suggestion ? (string as NSString).substring(with: selection) : nil, theme: theme)
        composer.anchor = selection.location
        // The selection is an offset into the text as it is now: if the text
        // changes while the composer is open, it would land on other words.
        let original = string
        composer.onSubmit = { [weak self] body, replacement in
            guard let self else { return nil }
            guard self.string == original else {
                return "The document changed. Cancel and select the text again."
            }
            self.setSelectedRange(selection)
            let id = replacement.map {
                self.addSuggestion(replacement: $0, body: body, author: self.author)
            } ?? self.addComment(body: body, author: self.author)
            guard id != nil else { return "Select text within one paragraph, outside code and other comments." }
            self.closeComposer()
            return nil
        }
        composer.onCancel = { [weak self] in self?.closeComposer() }
        composer.onResize = { [weak self] in self?.layoutReviewMargin() }
        reviewComposer = composer
        addSubview(composer)
        layoutReviewMargin()
        scrollToVisible(composer.frame)
        window?.makeFirstResponder(composer.replacementField ?? composer.bodyField)
    }

    func closeComposer() {
        guard let composer = reviewComposer else { return }
        let hadFocus = (window?.firstResponder as? NSView).map { $0.isDescendant(of: composer) } ?? false
        composer.removeFromSuperview()
        reviewComposer = nil
        layoutReviewMargin()
        if hadFocus { window?.makeFirstResponder(self) }
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
