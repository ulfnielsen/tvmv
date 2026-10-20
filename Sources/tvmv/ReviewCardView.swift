import AppKit
import TVMVCore

/// What a margin card shows: one per thread, plus one per problem a hand
/// edit can leave (a thread whose anchor is gone, an anchor whose thread is).
enum ReviewCards {
    struct Model: Equatable {
        enum Kind: Equatable { case comment, suggestion, orphanThread, danglingAnchor }
        var id: String
        var kind: Kind
        var entries: [ReviewMarkup.Entry]
        /// A suggestion's change in brief ("old → new", "+ added", "− removed").
        var change: String?
        /// The source location the card lines up with: its anchor's first
        /// visible character (an orphan thread's own start).
        var anchor: Int

        /// Same card content (positions aside): the card can stay as it is.
        func showsSame(as other: Model) -> Bool {
            id == other.id && kind == other.kind && change == other.change
                && entries.map { [$0.author, $0.date, $0.kind.rawValue, $0.body] }
                    == other.entries.map { [$0.author, $0.date, $0.kind.rawValue, $0.body] }
        }
    }

    static func models(_ review: ReviewMarkup.Review) -> [Model] {
        let units = Array(review.text.utf16)
        func slice(_ r: Range<Int>?) -> String {
            guard let r, r.upperBound <= units.count else { return "" }
            return String(decoding: units[r], as: UTF16.self)
        }
        var models: [Model] = []
        var seen = Set<String>()
        for anchor in review.anchors where seen.insert(anchor.id).inserted {
            let start = anchor.kind == .point ? anchor.ref.lowerBound : (anchor.old ?? anchor.inner).lowerBound
            guard let thread = review.thread(id: anchor.id) else {
                models.append(Model(id: anchor.id, kind: .danglingAnchor, entries: [], change: nil, anchor: start))
                continue
            }
            let suggestion = review.anchors(id: anchor.id).contains { $0.kind.isSuggestion }
            var change: String?
            switch anchor.kind {
            case .substitution: change = "\(slice(anchor.old)) → \(slice(anchor.new))"
            case .insertion: change = "+ " + slice(anchor.inner)
            case .deletion: change = "− " + slice(anchor.inner)
            case .highlight, .point: change = nil
            }
            models.append(Model(id: anchor.id, kind: suggestion ? .suggestion : .comment,
                                entries: thread.entries, change: change, anchor: start))
        }
        for thread in review.threads where !seen.contains(thread.id) && seen.insert(thread.id).inserted {
            models.append(Model(id: thread.id, kind: .orphanThread, entries: thread.entries, change: nil,
                                anchor: thread.range.lowerBound))
        }
        return models.sorted { $0.anchor < $1.anchor }
    }
}

/// One thread's card: its entries, Accept/Reject or Resolve, and a reply field.
@MainActor
final class ReviewCardView: NSView {
    enum Action: Equatable { case accept, reject, resolve, reply(String), deleteThread, removeMarkup }

    /// Its thread; the anchor position is refreshed as the text changes.
    var model: ReviewCards.Model
    var id: String { model.id }
    /// The width it was last laid out at (nil: not yet).
    private(set) var fittedWidth: CGFloat?
    var onAction: ((Action) -> Void)?
    let replyField = NSTextField()
    var isFocused = false { didSet { updateBorder() } }

    private let stack = NSStackView()
    let theme: NativeTheme
    private var bodyLabels: [NSTextField] = []
    private var replyWidth: NSLayoutConstraint?

    init(model: ReviewCards.Model, theme: NativeTheme) {
        self.model = model
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 80))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = theme.paperDeep.cgColor
        updateBorder()
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func label(_ text: NSAttributedString) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: text)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.isSelectable = true
        bodyLabels.append(field)
        return field
    }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        addSubview(stack)

        let small = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let heading: String
        switch model.kind {
        case .comment: heading = "COMMENT"
        case .suggestion: heading = "SUGGESTION"
        case .orphanThread: heading = "THREAD WITHOUT ANCHOR"
        case .danglingAnchor: heading = "MARKUP WITHOUT THREAD"
        }
        stack.addArrangedSubview(label(NSAttributedString(string: heading, attributes: [
            .font: small, .foregroundColor: model.kind == .comment || model.kind == .suggestion ? theme.muted : theme.accent,
            .kern: 0.6])))
        if let change = model.change {
            stack.addArrangedSubview(label(NSAttributedString(string: change, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: theme.ink])))
        }
        for entry in model.entries {
            let text = NSMutableAttributedString(string: "@" + entry.author, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: theme.ink])
            text.append(NSAttributedString(string: "  " + entry.date + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.muted]))
            text.append(NSAttributedString(string: entry.body, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.inkSoft]))
            stack.addArrangedSubview(label(text))
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 6
        func add(_ title: String, _ action: Action) {
            let button = ClosureButton(title: title) { [weak self] in self?.onAction?(action) }
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            buttons.addArrangedSubview(button)
        }
        switch model.kind {
        case .suggestion: add("Accept", .accept); add("Reject", .reject)
        case .comment: add("Resolve", .resolve)
        case .orphanThread: add("Delete Thread", .deleteThread)
        case .danglingAnchor: add("Remove Markup", .removeMarkup)
        }
        stack.addArrangedSubview(buttons)

        if model.kind == .comment || model.kind == .suggestion {
            replyField.placeholderString = "Reply"
            replyField.controlSize = .small
            replyField.font = .systemFont(ofSize: 12)
            replyField.target = self
            replyField.action = #selector(replyEntered(_:))
            stack.addArrangedSubview(replyField)
            replyWidth = replyField.widthAnchor.constraint(equalToConstant: 200)
            replyWidth?.isActive = true
        }
    }

    @objc private func replyEntered(_ sender: Any?) { submitReply() }

    /// Send the reply field's text, if any, and clear it.
    func submitReply() {
        let body = replyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        replyField.stringValue = ""
        onAction?(.reply(body))
    }

    func button(_ title: String) -> NSButton? {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(self)
    }

    /// Lay the card out at `width`; its height follows the content.
    func fit(width: CGFloat) {
        let inner = width - stack.edgeInsets.left - stack.edgeInsets.right
        for field in bodyLabels { field.preferredMaxLayoutWidth = inner }
        replyWidth?.constant = inner
        let height = stack.fittingSize.height
        stack.frame = NSRect(x: 0, y: 0, width: width, height: height)
        setFrameSize(NSSize(width: width, height: height))
        fittedWidth = width
    }

    private func updateBorder() {
        layer?.borderWidth = isFocused ? 2 : 1
        layer?.borderColor = (isFocused ? theme.accent : theme.muted.withAlphaComponent(0.3)).cgColor
    }
}

/// A button that runs a closure.
@MainActor
final class ClosureButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        self.handler = handler
        target = self
        action = #selector(fire(_:))
    }

    @objc private func fire(_ sender: Any?) { handler() }
}

/// The popover for a new comment or suggestion: a replacement field for a
/// suggestion (starting from the selected text), a note, and Add.
@MainActor
final class ReviewComposerView: NSView {
    let bodyField = NSTextField()
    let replacementField: NSTextField?
    let messageLabel = NSTextField(labelWithString: "")
    /// Returns nil once added, or why it couldn't be (shown in the label).
    var onSubmit: ((_ body: String, _ replacement: String?) -> String?)?
    var onCancel: (() -> Void)?

    init(suggestion: String?) {
        replacementField = suggestion.map { NSTextField(string: $0) }
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 10))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        let title = NSTextField(labelWithString: suggestion == nil ? "Comment" : "Suggest Edit")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(title)
        if let replacementField {
            replacementField.placeholderString = "Replace with (empty deletes)"
            stack.addArrangedSubview(replacementField)
            replacementField.widthAnchor.constraint(equalToConstant: 292).isActive = true
        }
        bodyField.placeholderString = suggestion == nil ? "Comment" : "Note (optional)"
        bodyField.target = self
        bodyField.action = #selector(enter(_:))
        replacementField?.target = self
        replacementField?.action = #selector(enter(_:))
        // Return submits; leaving a field (Tab to the next) must not.
        for field in [bodyField, replacementField].compactMap({ $0 }) {
            (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        }
        stack.addArrangedSubview(bodyField)
        bodyField.widthAnchor.constraint(equalToConstant: 292).isActive = true
        messageLabel.textColor = .systemRed
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.isHidden = true
        stack.addArrangedSubview(messageLabel)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        let cancel = ClosureButton(title: "Cancel") { [weak self] in self?.onCancel?() }
        cancel.keyEquivalent = "\u{1b}"
        let add = ClosureButton(title: "Add") { [weak self] in self?.submit() }
        add.keyEquivalent = "\r"
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(add)
        stack.addArrangedSubview(buttons)
        addSubview(stack)
        let size = stack.fittingSize
        stack.frame = NSRect(origin: .zero, size: size)
        setFrameSize(size)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func enter(_ sender: Any?) { submit() }

    private var submitted = false

    /// A field's text as typed (its live editor's, while it is being edited).
    private static func text(of field: NSTextField) -> String {
        (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
    }

    /// Add the comment, once.
    func submit() {
        guard !submitted else { return }
        let body = Self.text(of: bodyField).trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementField.map(Self.text(of:))
        if replacementField == nil, body.isEmpty { return }
        if let problem = onSubmit?(body, replacement) {
            messageLabel.stringValue = problem
            messageLabel.isHidden = false
        } else {
            submitted = true
        }
    }
}
