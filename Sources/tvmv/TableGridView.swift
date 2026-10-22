import AppKit
import TVMVCore

/// A GFM table shown as an editable grid over its hidden source.
///
/// Each cell is a small `DocumentTextView` (same inline rendering) whose text
/// is the cell's source. Typing in a cell patches that cell's source in the
/// document through the document's own edit path — one undo stack — and the
/// grid refreshes from the re-parsed table. Structural commands rewrite the
/// table neatly (`TableSource.reformat`).
final class TableGridView: NSView {
    weak var document: DocumentTextView?
    /// Which of the document's tables this grid shows.
    var index = 0
    private(set) var cells: [[DocumentTextView]] = []
    private var table: MarkdownLayout.Table?
    private var theme: NativeTheme?
    private var columnWidths: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    /// The cell whose own edit is being applied: it already shows the text.
    private var editingCell: DocumentTextView?

    static let cellInset = NSSize(width: 7, height: 5)
    static let minColumnWidth: CGFloat = 48

    override var isFlipped: Bool { true }

    init(document: DocumentTextView) {
        self.document = document
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var cellTexts: [[String]] { cells.map { $0.map(\.string) } }

    func cell(row: Int, column: Int) -> DocumentTextView { cells[row][column] }

    // MARK: Update

    func update(table: MarkdownLayout.Table, text: NSString, width: CGFloat, theme: NativeTheme, editable: Bool) {
        let columns = max(table.alignments.count, table.rows.map(\.count).max() ?? 0)
        let texts = table.rows.map { row in
            (0..<columns).map { $0 < row.count ? text.substring(with: row[$0]) : "" }
        }
        let shapeChanged = texts.count != cells.count || cells.first?.count != columns
        if shapeChanged || theme != self.theme {
            rebuild(texts, alignments: table.alignments, theme: theme, editable: editable)
        } else {
            for (r, row) in texts.enumerated() {
                for (c, value) in row.enumerated() where cells[r][c] !== editingCell && cells[r][c].string != value {
                    let selection = cells[r][c].selectedRange()
                    cells[r][c].load(value)
                    cells[r][c].setSelectedRange(NSRange(location: min(selection.location, (value as NSString).length), length: 0))
                }
            }
        }
        self.table = table
        self.theme = theme
        layoutCells(width: width)
    }

    func setEditable(_ editable: Bool) {
        cells.joined().forEach { $0.isEditable = editable }
    }

    private func rebuild(_ texts: [[String]], alignments: [MarkdownLayout.Table.Alignment],
                         theme: NativeTheme, editable: Bool) {
        let focus = cells.enumerated().lazy.compactMap { r, row in
            row.firstIndex { $0.window?.firstResponder === $0 }.map { (r, $0) }
        }.first
        cells.joined().forEach { $0.removeFromSuperview() }
        cells = texts.enumerated().map { r, row in
            row.enumerated().map { c, value in
                let cell = DocumentTextView.make(cell: true)
                var cellTheme = theme
                cellTheme.columnWidth = nil
                cellTheme.padding = 0
                cellTheme.textAlignment = c < alignments.count ? Self.textAlignment(alignments[c]) : .natural
                if r == 0 { cellTheme.body = NSFontManager.shared.convert(theme.body, toHaveTrait: .boldFontMask) }
                cell.cellHost = self
                cell.theme = cellTheme
                cell.drawsBackground = false
                cell.allowsUndo = false
                cell.isEditable = editable
                cell.textContainerInset = Self.cellInset
                cell.isVerticallyResizable = false
                cell.autoresizingMask = []
                cell.load(value)   // its edits reach cellDidEdit once processed
                addSubview(cell)
                return cell
            }
        }
        if let (r, c) = focus, r < cells.count, c < cells[r].count { window?.makeFirstResponder(cells[r][c]) }
    }

    static func textAlignment(_ alignment: MarkdownLayout.Table.Alignment) -> NSTextAlignment {
        switch alignment {
        case .left, .none: return .natural
        case .center: return .center
        case .right: return .right
        }
    }

    /// Columns take their content's width, scaled down to `width` when the
    /// table is wider than the text column; rows take their tallest cell.
    private func layoutCells(width: CGFloat) {
        guard let first = cells.first else { frame.size = .zero; return }
        let inset = Self.cellInset
        var natural = Array(repeating: Self.minColumnWidth, count: first.count)
        for row in cells {
            for (c, cell) in row.enumerated() {
                natural[c] = max(natural[c], cell.naturalTextWidth() + 2 * inset.width + 2)
            }
        }
        let total = natural.reduce(0, +)
        columnWidths = total <= width ? natural
            : natural.map { max(Self.minColumnWidth, ($0 * width / total).rounded(.down)) }
        rowHeights = cells.map { row in
            row.enumerated().map { c, cell in cell.textHeight(forWidth: columnWidths[c] - 2 * inset.width) + 2 * inset.height }
                .max() ?? 0
        }
        var y: CGFloat = 0
        for (r, row) in cells.enumerated() {
            var x: CGFloat = 0
            for (c, cell) in row.enumerated() {
                cell.frame = NSRect(x: x, y: y, width: columnWidths[c], height: rowHeights[r])
                x += columnWidths[c]
            }
            y += rowHeights[r]
        }
        setFrameSize(NSSize(width: columnWidths.reduce(0, +) + 1, height: y + 1))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme, !rowHeights.isEmpty else { return }
        theme.paperDeep.setFill()
        NSRect(x: 0, y: 0, width: bounds.width - 1, height: rowHeights[0]).fill()
        theme.muted.withAlphaComponent(0.35).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        // Horizontal rules.
        var top: CGFloat = 0.5
        path.move(to: NSPoint(x: 0, y: top)); path.line(to: NSPoint(x: bounds.width - 0.5, y: top))
        for h in rowHeights {
            top += h
            path.move(to: NSPoint(x: 0, y: top)); path.line(to: NSPoint(x: bounds.width - 0.5, y: top))
        }
        // Vertical rules.
        var left: CGFloat = 0.5
        path.move(to: NSPoint(x: left, y: 0)); path.line(to: NSPoint(x: left, y: bounds.height - 0.5))
        for w in columnWidths {
            left += w
            path.move(to: NSPoint(x: left, y: 0)); path.line(to: NSPoint(x: left, y: bounds.height - 0.5))
        }
        path.stroke()
    }

    // MARK: Editing

    private func position(of cell: DocumentTextView) -> (row: Int, column: Int)? {
        for (r, row) in cells.enumerated() { if let c = row.firstIndex(where: { $0 === cell }) { return (r, c) } }
        return nil
    }

    func cellDidEdit(_ cell: DocumentTextView, _ patch: TextPatcher.Patch) {
        guard let document, let (r, c) = position(of: cell) else { return }
        editingCell = cell
        document.applyCellEdit(table: index, row: r, column: c, patch)
        editingCell = nil
        // The cell may now differ from its source (an escaped "|"): resync
        // once its own edit has finished processing.
        DispatchQueue.main.async { [weak self] in
            guard let self, let doc = self.document, self.index < doc.layout.tables.count,
                  let (r, c) = self.position(of: cell) else { return }
            let table = doc.layout.tables[self.index]
            guard r < table.rows.count, c < table.rows[r].count else { return }
            let source = (doc.string as NSString).substring(with: table.rows[r][c])
            if cell.string != source {
                let caret = cell.selectedRange().location + ((source as NSString).length - (cell.string as NSString).length)
                cell.load(source)
                cell.setSelectedRange(NSRange(location: max(0, min(caret, (source as NSString).length)), length: 0))
            }
        }
    }

    enum Step { case next, previous, down }

    func move(from cell: DocumentTextView, _ step: Step) {
        guard let (r, c) = position(of: cell) else { return }
        let columns = cells[r].count
        var target: (Int, Int)?
        switch step {
        case .next: target = c + 1 < columns ? (r, c + 1) : (r + 1 < cells.count ? (r + 1, 0) : nil)
        case .previous: target = c > 0 ? (r, c - 1) : (r > 0 ? (r - 1, cells[r - 1].count - 1) : nil)
        case .down: target = r + 1 < cells.count ? (r + 1, min(c, cells[r + 1].count - 1)) : nil
        }
        guard let (tr, tc) = target else { NSSound.beep(); return }
        let next = cells[tr][tc]
        window?.makeFirstResponder(next)
        next.setSelectedRange(NSRange(location: (next.string as NSString).length, length: 0))
    }

    func revealSource(from cell: DocumentTextView) {
        guard let document, index < document.layout.tables.count else { return }
        document.window?.makeFirstResponder(document)
        document.reveal(unit: document.layout.tables[index].range)
    }

    // MARK: Structure

    func insertRow(below row: Int) {
        document?.reformatTable(index) { cells, _ in
            cells.insert(Array(repeating: "", count: cells.first?.count ?? 1), at: min(row + 1, cells.count))
        }
    }

    func insertRow(above row: Int) {
        document?.reformatTable(index) { cells, _ in
            cells.insert(Array(repeating: "", count: cells.first?.count ?? 1), at: max(1, row))
        }
    }

    func deleteRow(_ row: Int) {
        guard row > 0 else { NSSound.beep(); return }   // the header row stays
        document?.reformatTable(index) { cells, _ in if row < cells.count, cells.count > 2 { cells.remove(at: row) } }
    }

    func insertColumn(after column: Int) {
        document?.reformatTable(index) { cells, alignments in
            for i in cells.indices { cells[i].insert("", at: min(column + 1, cells[i].count)) }
            alignments.insert(.none, at: min(column + 1, alignments.count))
        }
    }

    func deleteColumn(_ column: Int) {
        document?.reformatTable(index) { cells, alignments in
            guard (cells.first?.count ?? 0) > 1 else { return }
            for i in cells.indices where column < cells[i].count { cells[i].remove(at: column) }
            if column < alignments.count { alignments.remove(at: column) }
        }
    }

    func align(_ column: Int, _ alignment: MarkdownLayout.Table.Alignment) {
        document?.reformatTable(index) { _, alignments in
            if column < alignments.count { alignments[column] = alignment }
        }
    }

    // MARK: Hover controls

    /// While editing, the pointer over a cell shows a handle and "+" buttons
    /// on its column's top border and its row's left border. They live in the
    /// document view, outside the grid's own frame.
    private(set) lazy var columnHandle: NSButton = control("ellipsis.circle.fill", "Column") { [weak self] in
        self?.popColumnMenu()
    }
    private(set) lazy var rowHandle: NSButton = control("ellipsis.circle.fill", "Row") { [weak self] in
        self?.popRowMenu()
    }
    private(set) lazy var addColumnLeft: NSButton = control("plus.circle.fill", "Insert Column Left") { [weak self] in
        self?.act { grid, _, c in grid.insertColumn(after: c - 1) }
    }
    private(set) lazy var addColumnRight: NSButton = control("plus.circle.fill", "Insert Column Right") { [weak self] in
        self?.act { grid, _, c in grid.insertColumn(after: c) }
    }
    private(set) lazy var addRowAbove: NSButton = control("plus.circle.fill", "Insert Row Above") { [weak self] in
        self?.act { grid, r, _ in grid.insertRow(above: r) }
    }
    private(set) lazy var addRowBelow: NSButton = control("plus.circle.fill", "Insert Row Below") { [weak self] in
        self?.act { grid, r, _ in grid.insertRow(below: r) }
    }
    var hoverControls: [NSButton] { [columnHandle, rowHandle, addColumnLeft, addColumnRight, addRowAbove, addRowBelow] }
    private var hovered: (row: Int, column: Int)?

    private func control(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: "", handler: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imageScaling = .scaleProportionallyUpOrDown
        button.toolTip = label
        button.isHidden = true
        return button
    }

    private func act(_ change: (TableGridView, Int, Int) -> Void) {
        guard let (r, c) = hovered else { return }
        hover(at: nil)
        change(self, r, c)
    }

    private func popColumnMenu() { pop(columnMenu(), from: columnHandle) }
    private func popRowMenu() { pop(rowMenu(), from: rowHandle) }

    private func pop(_ menu: NSMenu, from button: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 2), in: button)
    }

    /// The cell under `point` (grid coordinates).
    private func cellIndex(at point: NSPoint) -> (row: Int, column: Int)? {
        for (r, row) in cells.enumerated() {
            for (c, cell) in row.enumerated() where cell.frame.contains(point) { return (r, c) }
        }
        return nil
    }

    /// Show the controls for the cell under `point` (grid coordinates), or
    /// hide them (nil, or not editing).
    func hover(at point: NSPoint?) {
        guard let point, let document, document.isEditable, !isHidden, let (r, c) = cellIndex(at: point) else {
            hovered = nil
            hoverControls.forEach { $0.isHidden = true }
            return
        }
        hovered = (r, c)
        let cell = cells[r][c].frame.offsetBy(dx: frame.minX, dy: frame.minY)
        let side: CGFloat = 20
        func place(_ button: NSButton, _ center: NSPoint) {
            if button.superview !== document { document.addSubview(button) }
            button.frame = NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            button.contentTintColor = button === columnHandle || button === rowHandle
                ? theme?.muted : theme?.accent
            button.isHidden = false
        }
        let above = frame.minY - side / 2 - 3
        place(columnHandle, NSPoint(x: cell.midX, y: above))
        place(addColumnLeft, NSPoint(x: cell.minX, y: above))
        place(addColumnRight, NSPoint(x: cell.maxX, y: above))
        place(rowHandle, NSPoint(x: frame.minX - side * 1.9, y: cell.midY))
        place(addRowAbove, NSPoint(x: frame.minX - side / 2 - 3, y: cell.minY))
        place(addRowBelow, NSPoint(x: frame.minX - side / 2 - 3, y: cell.maxY))
        addRowAbove.isHidden = r == 0   // the header stays the first row
    }

    /// The column handle's menu: insert, delete, align.
    func columnMenu() -> NSMenu {
        menu([.insertColumnLeft, .insertColumnRight, .deleteColumn, nil, .alignLeft, .alignCenter, .alignRight])
    }

    /// The row handle's menu; the header row can only get a row below it.
    func rowMenu() -> NSMenu {
        hovered?.row == 0 ? menu([.insertRowBelow]) : menu([.insertRowAbove, .insertRowBelow, .deleteRow])
    }

    private func menu(_ commands: [TableCommand?]) -> NSMenu {
        let menu = NSMenu()
        guard let (r, c) = hovered else { return menu }
        for command in commands {
            guard let command else { menu.addItem(.separator()); continue }
            let item = command.menuItem()
            item.action = #selector(DocumentTextView.performTableCommand(_:))
            item.target = cells[r][c]
            menu.addItem(item)
        }
        return menu
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil { hoverControls.forEach { $0.removeFromSuperview() } }
    }

    /// Table commands for a cell's context menu.
    func menuItems(for cell: DocumentTextView) -> [NSMenuItem] {
        guard position(of: cell) != nil, document?.isEditable == true else { return [] }
        var items: [NSMenuItem] = [.separator()]
        for command in TableCommand.allCases {
            if command == .alignLeft { items.append(.separator()) }
            let item = command.menuItem()
            item.action = #selector(DocumentTextView.performTableCommand(_:))
            item.target = cell
            items.append(item)
        }
        return items
    }

    /// Run `command` for `cell`'s row and column.
    func perform(_ command: TableCommand, from cell: DocumentTextView) {
        guard let (r, c) = position(of: cell), document?.isEditable == true else { NSSound.beep(); return }
        switch command {
        case .insertRowAbove: insertRow(above: r)
        case .insertRowBelow: insertRow(below: r)
        case .insertColumnLeft: insertColumn(after: c - 1)
        case .insertColumnRight: insertColumn(after: c)
        case .deleteRow: deleteRow(r)
        case .deleteColumn: deleteColumn(c)
        case .alignLeft: align(c, .left)
        case .alignCenter: align(c, .center)
        case .alignRight: align(c, .right)
        }
    }
}

/// The table commands: in a cell's context menu and the Table menu, each
/// with an icon and a shortcut.
enum TableCommand: String, CaseIterable {
    case insertRowAbove, insertRowBelow, insertColumnLeft, insertColumnRight, deleteRow, deleteColumn
    case alignLeft, alignCenter, alignRight

    var title: String {
        switch self {
        case .insertRowAbove: "Insert Row Above"
        case .insertRowBelow: "Insert Row Below"
        case .insertColumnLeft: "Insert Column Left"
        case .insertColumnRight: "Insert Column Right"
        case .deleteRow: "Delete Row"
        case .deleteColumn: "Delete Column"
        case .alignLeft: "Align Column Left"
        case .alignCenter: "Align Column Center"
        case .alignRight: "Align Column Right"
        }
    }

    /// SF Symbol name.
    var symbol: String {
        switch self {
        case .insertRowAbove: "arrow.up.to.line"
        case .insertRowBelow: "arrow.down.to.line"
        case .insertColumnLeft: "arrow.left.to.line"
        case .insertColumnRight: "arrow.right.to.line"
        case .deleteRow: "minus.rectangle"
        case .deleteColumn: "minus.square"
        case .alignLeft: "text.alignleft"
        case .alignCenter: "text.aligncenter"
        case .alignRight: "text.alignright"
        }
    }

    /// ⌃⌘ arrows insert, ⌃⌘⌫ / ⌃⌥⌘⌫ delete, ⌘{ ⌘| ⌘} align (the system's
    /// alignment keys). ⌥⌘↑/↓ are taken by Next/Previous Thread.
    var key: (equivalent: String, modifiers: NSEvent.ModifierFlags) {
        func f(_ key: Int) -> String { String(UnicodeScalar(UInt16(key))!) }
        switch self {
        case .insertRowAbove: return (f(NSUpArrowFunctionKey), [.control, .command])
        case .insertRowBelow: return (f(NSDownArrowFunctionKey), [.control, .command])
        case .insertColumnLeft: return (f(NSLeftArrowFunctionKey), [.control, .command])
        case .insertColumnRight: return (f(NSRightArrowFunctionKey), [.control, .command])
        case .deleteRow: return ("\u{8}", [.control, .command])
        case .deleteColumn: return ("\u{8}", [.control, .option, .command])
        case .alignLeft: return ("{", [.command])
        case .alignCenter: return ("|", [.command])
        case .alignRight: return ("}", [.command])
        }
    }

    /// A menu item for it (its command in `representedObject`).
    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: key.equivalent)
        item.keyEquivalentModifierMask = key.modifiers
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.representedObject = rawValue
        return item
    }
}
