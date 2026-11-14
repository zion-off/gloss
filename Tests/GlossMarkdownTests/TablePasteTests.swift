import Testing
@testable import GlossMarkdown

@Suite("table paste")
struct TablePasteTests {
    @Test("pasting a table starts it on a line of its own and leaves the caret after it")
    func paste() {
        let table = "| a | b |\n|---|---|\n| 1 | 2 |"
        let paste = { (pasted: String) in { (doc: MarkdownDocument, selection: Range<Int>) in
            TablePaste.edit(pasting: pasted, in: doc, selection: selection) } }
        #expect(editTable("note ⎸rest", paste(table)) == "note \n\(table)\n⎸\nrest")
        #expect(editTable("⎸| c | d |", paste(table)) == "\(table)\n⎸\n| c | d |")
        #expect(editTable("⎸", paste(table + "\n")) == "\(table)\n⎸")
        #expect(editTable("⎸", paste("intro\n" + table + "\n\nafter")) == "intro\n\(table)\n\nafter⎸")
        #expect(editTable("x⎸", paste("no | table here")) == nil)
    }
}
