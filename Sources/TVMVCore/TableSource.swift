import Foundation

/// Edits to a GFM table expressed as patches to its Markdown source.
///
/// Typing in a cell patches that cell's source in place (padding untouched,
/// so diffs stay small); structural changes — rows, columns, alignment —
/// rewrite the whole table neatly padded.
public enum TableSource {

    /// A cell's text as the grid edits it: its source, escapes included.
    public static func cellText(_ table: MarkdownLayout.Table, row: Int, column: Int, in text: NSString) -> String {
        text.substring(with: table.rows[row][column])
    }

    /// Map an edit of one cell's text to a patch of the document; a typed
    /// "|" is escaped so it can't split the cell.
    public static func cellEdit(_ table: MarkdownLayout.Table, row: Int, column: Int,
                                _ patch: TextPatcher.Patch) -> TextPatcher.Patch {
        let cell = table.rows[row][column]
        return .init(from: cell.location + patch.from, to: cell.location + patch.to,
                     insert: patch.insert.replacingOccurrences(of: "|", with: "\\|"))
    }

    /// Rewrite the table after `change` edits its cells (header row first)
    /// and column alignments. Rows are padded to the widest row.
    public static func reformat(_ table: MarkdownLayout.Table, in text: NSString,
                                _ change: (inout [[String]], inout [MarkdownLayout.Table.Alignment]) -> Void)
        -> TextPatcher.Patch {
        var cells = table.rows.map { $0.map { text.substring(with: $0) } }
        var alignments = table.alignments
        let columns = max(alignments.count, cells.map(\.count).max() ?? 0)
        cells = cells.map { $0 + Array(repeating: "", count: max(0, columns - $0.count)) }
        alignments += Array(repeating: .none, count: max(0, columns - alignments.count))
        change(&cells, &alignments)
        return .init(from: table.range.location, to: NSMaxRange(table.range), insert: render(cells, alignments))
    }

    static func render(_ cells: [[String]], _ alignments: [MarkdownLayout.Table.Alignment]) -> String {
        let columns = max(alignments.count, cells.map(\.count).max() ?? 0)
        let rows = cells.map { $0 + Array(repeating: "", count: max(0, columns - $0.count)) }
        let align = alignments + Array(repeating: .none, count: max(0, columns - alignments.count))
        let widths = (0..<columns).map { c in max(3, rows.map { $0[c].count }.max() ?? 0) }

        func pad(_ s: String, _ width: Int, _ alignment: MarkdownLayout.Table.Alignment) -> String {
            let gap = max(0, width - s.count)
            switch alignment {
            case .right: return String(repeating: " ", count: gap) + s
            case .center: return String(repeating: " ", count: gap / 2) + s + String(repeating: " ", count: gap - gap / 2)
            default: return s + String(repeating: " ", count: gap)
            }
        }
        func line(_ row: [String]) -> String {
            "| " + (0..<columns).map { pad(row[$0], widths[$0], align[$0]) }.joined(separator: " | ") + " |"
        }
        let delimiter = "| " + (0..<columns).map { c -> String in
            let w = widths[c]
            switch align[c] {
            case .left: return ":" + String(repeating: "-", count: w - 1)
            case .right: return String(repeating: "-", count: w - 1) + ":"
            case .center: return ":" + String(repeating: "-", count: w - 2) + ":"
            case .none: return String(repeating: "-", count: w)
            }
        }.joined(separator: " | ") + " |"
        guard let header = rows.first else { return "" }
        return ([line(header), delimiter] + rows.dropFirst().map(line)).joined(separator: "\n")
    }
}
