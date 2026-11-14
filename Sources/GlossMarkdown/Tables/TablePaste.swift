/// Pasting markdown that holds a pipe table: the text goes in unchanged, but a table that starts
/// the paste starts a line, and one that ends it is followed by a line break, so the caret lands
/// outside the table and the grid shows at once. When text follows on the same line, a blank line
/// keeps it from running on as a table row. Only the plain-text string is looked at.
public enum TablePaste {
    /// Nil when the pasted text has no table: paste as usual.
    public static func edit(pasting string: String, in document: MarkdownDocument, selection: Range<Int>) -> EditResult? {
        let pasted = MarkdownParser.notes.parse(string)
        let content = pasted.blocks.filter { $0.kind != .blank }
        guard content.contains(where: { $0.kind == .table }), let first = content.first, let last = content.last else { return nil }
        let text = document.text
        var insertion = string
        let startLine = text.lines[text.lineIndex(containing: selection.lowerBound)]
        if first.kind == .table, !text.isBlank(startLine.lowerBound..<selection.lowerBound) { insertion = "\n" + insertion }
        var caretOffset: Int?
        if last.kind == .table {
            if !string.hasSuffix("\n") { insertion += "\n" }
            caretOffset = insertion.utf16.count
            let endLine = text.lines[text.lineIndex(containing: selection.upperBound)]
            if !text.isBlank(selection.upperBound..<endLine.upperBound) { insertion += "\n" }
        }
        let caret = selection.lowerBound + (caretOffset ?? insertion.utf16.count)
        return EditResult(edits: [TextEdit(range: selection, replacement: insertion)], selection: caret..<caret)
    }
}
