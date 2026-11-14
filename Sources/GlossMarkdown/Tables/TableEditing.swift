/// Text edits on pipe tables. Each only appends what it needs (a row, a cell per line) and never
/// rewrites cells it doesn't add, so the user's spacing and alignment survive.
public enum TableEditing {
    /// An empty row of `columns` cells. Always with both outer pipes: without a trailing pipe an
    /// empty last cell can't be written at all (`a |` is one cell).
    static func emptyRow(columns: Int) -> String {
        "|" + String(repeating: "  |", count: max(columns, 1))
    }

    /// Where typing goes in a fresh `emptyRow`: inside its first cell, `| ⎸ |`.
    static let firstCellOffset = 2

    /// Return inside a table, like Return in a list: a new empty row under the caret's row (under
    /// the delimiter row when on the header), and on an empty last row the end of the table (the
    /// row is cleared, leaving an empty line below it). Nil means a plain newline: a selection, or
    /// the caret at the very start of the header line, where Return moves the table down.
    public static func newline(in document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        guard selection.isEmpty else { return nil }
        let caret = selection.lowerBound
        guard let table = MarkdownTable.all(in: document).first(where: { $0.range.lowerBound <= caret && caret <= $0.range.upperBound }),
              let index = table.lineIndex(containing: caret) else { return nil }
        let line = table.lines[index]
        if index == 0, caret <= document.text.firstNonBlank(in: line.line) { return nil }
        if index >= 2, index == table.lines.count - 1, line.isEmpty {
            return EditResult(edits: [.delete(line.line)], selection: line.line.lowerBound..<line.line.lowerBound)
        }
        let after = table.lines[max(index, 1)].line.upperBound
        let caretAfter = after + 1 + firstCellOffset
        return EditResult(edits: [.insert("\n" + emptyRow(columns: table.columnCount), at: after)], selection: caretAfter..<caretAfter)
    }

    /// Appends an empty row. The selection stays on the text it was on.
    public static func addRow(to table: MarkdownTable, selection: Range<Int>) -> EditResult {
        EditResult(edits: [.insert("\n" + emptyRow(columns: table.columnCount), at: table.range.upperBound)],
                   originalSelection: selection, lowerAfterInsertions: false, upperAfterInsertions: false)
    }

    /// Appends a column: an empty cell on the header and body rows, `---` on the delimiter row
    /// (no alignment; the existing columns keep theirs). A row with a trailing pipe gets its new
    /// cell after it; a row without one gets it with a trailing pipe, the only way to write an
    /// empty last cell. The selection stays on the text it was on.
    public static func addColumn(to table: MarkdownTable, selection: Range<Int>) -> EditResult {
        let edits: [TextEdit] = table.lines.enumerated().map { index, row in
            let isDelimiter = index == 1
            if row.hasTrailingPipe, let pipe = row.pipes.last {
                return .insert(isDelimiter ? " --- |" : "  |", at: pipe + 1)
            }
            let end = row.cells.last?.range.upperBound ?? row.line.upperBound
            return .insert(isDelimiter ? " | ---" : " |  |", at: end)
        }
        return EditResult(edits: edits, originalSelection: selection, lowerAfterInsertions: false, upperAfterInsertions: false)
    }
}
