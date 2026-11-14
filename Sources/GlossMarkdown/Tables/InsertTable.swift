/// The `/table` command: a two-column table with a header and one row, the caret in the first
/// header cell. On a blank line it takes the line; otherwise it goes on the line below.
public struct InsertTable: MarkdownEditCommand {
    static let template = TableEditing.emptyRow(columns: 2) + "\n| --- | --- |\n" + TableEditing.emptyRow(columns: 2)

    public init() {}
    public func isActive(_ document: MarkdownDocument, selection: Range<Int>) -> Bool { false }

    public func edit(_ document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        let text = document.text
        let line = text.lines[text.lineIndex(containing: selection.lowerBound)]
        if text.isBlank(line) {
            let caret = line.lowerBound + TableEditing.firstCellOffset
            return EditResult(edits: [TextEdit(range: line, replacement: Self.template)], selection: caret..<caret)
        }
        let caret = line.upperBound + 1 + TableEditing.firstCellOffset
        return EditResult(edits: [.insert("\n" + Self.template, at: line.upperBound)], selection: caret..<caret)
    }
}
