import Testing
@testable import GlossMarkdown

func parseNotes(_ source: String) -> MarkdownDocument { MarkdownParser.notes.parse(source) }

/// The table's cells as text, row by row (delimiter row included).
func tableCells(_ source: String) -> [[String]]? {
    let doc = parseNotes(source)
    guard let table = MarkdownTable.all(in: doc).first else { return nil }
    return table.lines.map { $0.cells.map { doc.text[$0.contentRange] } }
}

@Suite("table parsing")
struct TableParsingTests {
    @Test("a header, a delimiter and rows make one block with cells and alignments")
    func basic() throws {
        let source = "| name | qty |\n| :--- | ---: |\n| tea  | 2   |\nafter"
        let doc = parseNotes(source)
        #expect(doc.blocks.map(\.kind) == [.table, .paragraph])
        let table = try #require(MarkdownTable(doc.blocks[0]))
        #expect(table.columnCount == 2)
        #expect(table.alignments == [.left, .right])
        #expect(table.body.count == 1)
        #expect(tableCells(source) == [["name", "qty"], [":---", "---:"], ["tea", "2"]])
        #expect(doc.text[table.range] == "| name | qty |\n| :--- | ---: |\n| tea  | 2   |")
    }

    @Test("outer pipes are optional, a header and delimiter alone are a table, alignment reads every colon form")
    func shapes() {
        #expect(tableCells("a | b\n--- | :-:") == [["a", "b"], ["---", ":-:"]])
        #expect(tableCells("| a | b\n|---|---\n| 1 | 2") == [["a", "b"], ["---", "---"], ["1", "2"]])
        #expect(MarkdownTable.all(in: parseNotes("a | b\n-- | :-:")).first?.alignments == [TableAlignment.none, .center])
        #expect(tableCells("|a|\n|-|") == [["a"], ["-"]])
    }

    @Test("rows end at a blank line, a line without a pipe, or a line another block claims")
    func ends() {
        #expect(parseNotes("|a|\n|-|\n|1|\n\n|2|").blocks.map(\.kind) == [.table, .blank, .paragraph])
        #expect(parseNotes("|a|\n|-|\nplain").blocks.map(\.kind) == [.table, .paragraph])
        #expect(parseNotes("|a|\n|-|\n# h | x").blocks.map(\.kind) == [.table, .heading])
        #expect(parseNotes("|a|\n|-|\n- item | x").blocks.map(\.kind) == [.table, .listItem])
        #expect(parseNotes("- a | b\n- | -").blocks.map(\.kind) == [.listItem, .listItem])  // a list item is never a header
    }

    @Test("malformed or ragged tables stay paragraphs, whole")
    func degrades() {
        let kinds = { (source: String) in parseNotes(source).blocks.map(\.kind) }
        #expect(kinds("| a | b |\n| --- | --- |\n| 1 |") == [.paragraph, .paragraph, .paragraph])  // ragged row
        #expect(kinds("| a | b |\n| --- |") == [.paragraph, .paragraph])  // delimiter count differs
        #expect(kinds("| a | b |\n| 1 | 2 |") == [.paragraph, .paragraph])  // no delimiter row
        #expect(kinds("| a | b |\n| -x- | --- |") == [.paragraph, .paragraph])  // not a delimiter
        #expect(kinds("| a |\n| : |") == [.paragraph, .paragraph])
        #expect(kinds("| a | b | c |\n|---|---|\n|1|2|") == [.paragraph, .paragraph, .paragraph])  // extra pipe
        #expect(kinds("> | a |\n> |---|") == [.quote, .quote])  // not inside containers
    }

    @Test("escaped pipes and pipes in code spans are cell content")
    func pipesInContent() throws {
        let source = "| a \\| b | `x|y` |\n|---|---|\n| `p | q` | ``z`|`` |"
        #expect(tableCells(source) == [["a \\| b", "`x|y`"], ["---", "---"], ["`p | q`", "``z`|``"]])
        let table = try #require(MarkdownTable.all(in: parseNotes(source)).first)
        #expect(table.header.cells[0].inlines.map(\.kind) == [.escape])
        #expect(table.header.cells[1].inlines.map(\.kind) == [.code])
        // An unmatched backtick doesn't hide the pipes after it.
        #expect(tableCells("| `a | b |\n|---|---|") == [["`a", "b"], ["---", "---"]])
    }

    @Test("CJK and emoji cells keep exact UTF-16 ranges")
    func wideText() throws {
        let source = "| 日本 | 😀 x |\n| --- | --- |\n| 🇯🇵 | é |"
        let doc = parseNotes(source)
        #expect(tableCells(source) == [["日本", "😀 x"], ["---", "---"], ["🇯🇵", "é"]])
        let table = try #require(MarkdownTable.all(in: doc).first)
        #expect(table.header.cells[1].contentRange.count == "😀 x".utf16.count)
    }

    @Test("the standard dialect (exports, cli, search) still reads tables as paragraphs")
    func standardUnchanged() {
        #expect(MarkdownParser.standard.parse("| a |\n|---|").blocks.map(\.kind) == [.paragraph, .paragraph])
    }
}
