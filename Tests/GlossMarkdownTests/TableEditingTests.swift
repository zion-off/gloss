import Testing
@testable import GlossMarkdown

/// Runs a table edit on marked text. The caret is `⎸`: tables are full of the usual `|` marker.
func editTable(_ marked: String, _ make: (MarkdownDocument, Range<Int>) -> EditResult?) -> String? {
    let caret = Array(marked.utf16).firstIndex(of: Array("⎸".utf16)[0])!
    let text = String(marked.filter { $0 != "⎸" })
    guard let result = make(parseNotes(text), caret..<caret) else { return nil }
    var units = Array(result.apply(to: text).utf16)
    units.insert(contentsOf: Array("⎸".utf16), at: result.selection.lowerBound)
    return String(decoding: units, as: UTF16.self)
}

@Suite("table edits")
struct TableEditTests {
    let newline = { (doc: MarkdownDocument, selection: Range<Int>) in TableEditing.newline(in: doc, selection: selection) }

    @Test("return on a row adds an empty row under it with the caret in its first cell")
    func returnAddsRow() {
        #expect(editTable("|a|b|\n|-|-|\n|1|2⎸|", newline) == "|a|b|\n|-|-|\n|1|2|\n| ⎸ |  |")
        #expect(editTable("|a|b|\n|-|-|\n|1⎸|2|\n|3|4|", newline) == "|a|b|\n|-|-|\n|1|2|\n| ⎸ |  |\n|3|4|")
        // On the header (or the delimiter row) the new row is the first body row.
        #expect(editTable("|a⎸|b|\n|-|-|", newline) == "|a|b|\n|-|-|\n| ⎸ |  |")
        #expect(parseNotes("|a|b|\n|-|-|\n|  |  |").blocks.map(\.kind) == [.table])
    }

    @Test("return on an empty last row ends the table; at the header's start it moves the table down")
    func returnEnds() {
        #expect(editTable("|a|b|\n|-|-|\n|1|2|\n| ⎸ |  |", newline) == "|a|b|\n|-|-|\n|1|2|\n⎸")
        #expect(editTable("⎸|a|b|\n|-|-|", newline) == nil)
        #expect(editTable("text⎸\n|a|\n|-|", newline) == nil)
        #expect(TableEditing.newline(in: parseNotes("|a|\n|-|"), selection: 1..<2) == nil)
    }

    @Test("add row appends an empty row and the caret stays on its text")
    func addRow() throws {
        let doc = parseNotes("|a|b|\n|:-|-:|\n|1|2|\nafter")
        let table = try #require(MarkdownTable.all(in: doc).first)
        let caret = doc.text.length  // the end of "after"
        let result = TableEditing.addRow(to: table, selection: caret..<caret)
        let text = result.apply(to: doc.text.string)
        #expect(text == "|a|b|\n|:-|-:|\n|1|2|\n|  |  |\nafter")
        #expect(result.selection == text.utf16.count..<text.utf16.count)
        #expect(MarkdownTable.all(in: parseNotes(text)).first?.body.count == 2)
    }

    @Test("add column appends a cell to every line, keeps alignment, and keeps the table valid")
    func addColumn() throws {
        let check = { (source: String, expected: String) in
            let table = try #require(MarkdownTable.all(in: parseNotes(source)).first)
            let text = TableEditing.addColumn(to: table, selection: 0..<0).apply(to: source)
            #expect(text == expected)
            let grown = try #require(MarkdownTable.all(in: parseNotes(text)).first)
            #expect(grown.columnCount == table.columnCount + 1)
            #expect(grown.alignments == table.alignments + [.none])
        }
        try check("| a | b |\n| :-- | --: |\n| 1 | 2 |", "| a | b |  |\n| :-- | --: | --- |\n| 1 | 2 |  |")
        try check("a | b\n:-: | ---\n1 | 2", "a | b |  |\n:-: | --- | ---\n1 | 2 |  |")
        try check("| a \\|\n|---\n| `x|`", "| a \\| |  |\n|--- | ---\n| `x|` |  |")
    }
}
