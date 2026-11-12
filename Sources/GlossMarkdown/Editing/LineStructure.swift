/// The leading markers of one line: indentation, quote markers and the leaf block's marker.
struct LineStructure {
    let line: Range<Int>
    let block: Block
    let leaf: Block
    /// Offset just after all `>` markers (line start when there are none).
    let quoteEnd: Int
    /// The heading/list marker of the leaf (empty at `contentStart` when none).
    let marker: Range<Int>
    let contentStart: Int

    init(document: MarkdownDocument, lineIndex: Int) {
        let line = document.text.lines[lineIndex]
        self.line = line
        let block = document.blocks.first { $0.range.lowerBound <= line.lowerBound && line.upperBound <= $0.range.upperBound }
            ?? Block(kind: .paragraph, range: line, contentRange: line)
        self.block = block
        var quoteEnd = line.lowerBound
        var cursor = block
        while cursor.kind == .quote, let child = cursor.children.first {
            quoteEnd = cursor.syntax.last?.upperBound ?? quoteEnd
            cursor = child
        }
        self.leaf = cursor
        self.quoteEnd = quoteEnd
        let hasMarker = (cursor.kind == .heading || cursor.kind == .listItem) && cursor.syntax.first != nil
        let content = hasMarker ? cursor.contentRange.lowerBound : document.text.firstNonBlank(in: quoteEnd..<line.upperBound)
        self.contentStart = content
        self.marker = hasMarker ? cursor.syntax[0] : content..<content
    }

    var isBlank: Bool { leaf.kind == .blank }
    var isCode: Bool { block.kind == .codeBlock }
    /// Leading whitespace between the quote markers and the leaf marker.
    var indentRange: Range<Int> { quoteEnd..<marker.lowerBound }

    static func all(in document: MarkdownDocument, touching selection: Range<Int>) -> [LineStructure] {
        document.text.lineIndices(touching: selection).map { LineStructure(document: document, lineIndex: $0) }
    }
}
