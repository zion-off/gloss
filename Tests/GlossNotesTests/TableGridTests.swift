import Testing
@testable import GlossNotes
import GlossMarkdown

@Suite("table grid")
struct TableGridTests {
    /// Two columns, a 30 pt header and two body rows; margin 6, rule band 1.
    let layout = TableGridLayout(columnWidths: [100, 200], rowHeights: [30, 20, 25])

    @Test("each source line draws one band of the grid, the margins on the first and last")
    func bands() {
        #expect(layout.lineHeights == [36, 1, 20, 31])
        #expect(layout.lineTops == [0, 36, 37, 57])
        #expect(layout.height == 88)
        #expect((layout.gridTop, layout.gridBottom) == (6, 82))
        #expect(layout.rowTops == [6, 37, 57])
        #expect(layout.rowRules == [36.5, 57])
        #expect(layout.columnEdges == [0, 100, 300])
        #expect((0...3).map(TableGridLayout.gridRow(ofLine:)) == [0, nil, 1, 2])
        #expect([0, 1, 2].map(TableGridLayout.lineIndex(ofGridRow:)) == [0, 2, 3])
        // A header with no body rows: the delimiter line closes the grid, with no rule inside.
        let bare = TableGridLayout(columnWidths: [100], rowHeights: [30])
        #expect(bare.lineHeights == [36, 7] && bare.rowRules.isEmpty && bare.gridBottom == 37)
    }

    @Test("a point hits a divider within reach, else the cell under it; margins and edges hit nothing")
    func hits() {
        #expect(layout.hit(x: 103, y: 20) == .divider(0))
        #expect(layout.hit(x: 50, y: 20) == .cell(row: 0, column: 0))
        #expect(layout.hit(x: 150, y: 36.5) == .cell(row: 0, column: 1))  // the rule band is the header's
        #expect(layout.hit(x: 150, y: 60) == .cell(row: 2, column: 1))
        #expect(layout.hit(x: 50, y: 3) == nil)
        #expect(layout.hit(x: 300, y: 20) == nil)
        #expect(layout.hit(x: 2, y: 20) == .cell(row: 0, column: 0))  // the outer edge is not a divider
        // Clicks in the margins and past the edges still find a cell.
        #expect(layout.nearestCell(x: -5, y: 2) == (0, 0) && layout.nearestCell(x: 400, y: 87) == (2, 1))
    }

    @Test("cell text sits inside the padding; the handles centre on the bottom and right edges")
    func placement() {
        #expect(layout.textFrame(row: 1, column: 1) == GridRect(x: 108, y: 42, width: 184, height: 10))
        #expect(layout.addRowHandle == GridRect(x: 141, y: 73, width: 18, height: 18))
        #expect(layout.addColumnHandle == GridRect(x: 291, y: 35, width: 18, height: 18))
        #expect(TableGridLayout.naturalWidths(textWidths: [[10, 40], [30, 5]]) == [46, 56])
        #expect(TableGridLayout.rowHeight(textHeights: [12, 40], lineHeight: 16) == 50)
        #expect(TableGridLayout.rowHeight(textHeights: [0], lineHeight: 16) == 26)
    }

    @Test("drawn cells keep their inline styles and drop the markdown syntax")
    func cellText() throws {
        let doc = MarkdownParser.notes.parse("| h |\n|---|\n| **tea** [x](https://y) a\\|b |")
        let spans = NotesStyler().spans(for: doc)
        let table = try #require(MarkdownTable.all(in: doc).first)
        let runs = TableCellText.runs(table.body[0].cells[0].contentRange, in: doc.text, spans: spans, theme: .standard)
        #expect(runs.map(\.text) == ["tea", " ", "x", " a|b"])
        #expect(runs[0].style.bold == true && runs[2].style.color == .link && runs[3].style == runs[1].style)
        let header = TableCellText.runs(table.header.cells[0].contentRange, in: doc.text, spans: spans, theme: .standard)
        #expect(header.map(\.text) == ["h"] && header[0].style.bold == true && header[0].style.font == nil)
        // A drawn table's text is hidden under the grid, its lines laid out as table lines.
        let grid = NotesTheme.standard.runs(for: [StyleSpan(range: 0..<3, role: NotesRole.tableGrid)], length: 3)
        #expect(grid.first?.style.hidden == true && grid.first?.style.block == .table)
    }
}
