import Testing
@testable import GlossMarkdown

@Suite("insert table")
struct InsertTableTests {
    @Test("/table puts a 2×2 table on the line, the caret in the first header cell")
    func insertTable() {
        let insert = { (doc: MarkdownDocument, selection: Range<Int>) in InsertTable().edit(doc, selection: selection) }
        #expect(editTable("⎸", insert) == "| ⎸ |  |\n| --- | --- |\n|  |  |")
        #expect(editTable("words⎸", insert) == "words\n| ⎸ |  |\n| --- | --- |\n|  |  |")
        #expect(MarkdownTable.all(in: parseNotes(InsertTable.template)).first?.columnCount == 2)
    }
}
