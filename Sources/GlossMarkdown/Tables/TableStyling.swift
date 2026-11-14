extension StyleRole {
    /// A table's markdown while it shows as text: monospaced, so padded columns line up.
    public static let tableSource = StyleRole("tableSource")
    /// Pipes and the delimiter row: dimmed, but always shown (a table being edited needs them).
    public static let tableSyntax = StyleRole("tableSyntax")
    /// The header row's cell text.
    public static let tableHeader = StyleRole("tableHeader")
}

/// Styles a table's source. Cell inlines are styled by their own rules (the block's children
/// carry them); drawing the grid is the editor's business.
public struct TableRule: StylingRule {
    public init() {}

    public func spans(for block: Block, in text: MarkdownText) -> [StyleSpan] {
        guard let table = MarkdownTable(block) else { return [] }
        var spans = [StyleSpan(range: table.range, role: .tableSource)]
        for row in table.lines {
            spans += row.pipes.map { StyleSpan(range: $0..<$0 + 1, role: .tableSyntax) }
        }
        let delimiter = table.delimiter.line
        spans.append(StyleSpan(range: text.firstNonBlank(in: delimiter)..<delimiter.upperBound, role: .tableSyntax))
        spans += table.header.cells.filter { !$0.contentRange.isEmpty }.map { StyleSpan(range: $0.contentRange, role: .tableHeader) }
        return spans
    }
}
