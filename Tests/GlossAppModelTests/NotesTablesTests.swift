import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossMarkdown
import GlossNotes
import GlossTestSupport

@MainActor
struct NotesTablesTests {
    let table = "| a | b |\n| --- | --- |\n| 1 | 2 |"

    func loaded(_ body: String) async throws -> (TestLibrary, NotesEditorModel, Page) {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        try await lib.services.pages.updateBody(root.id, to: body)
        let page = try #require(try await lib.services.pages.page(root.id))
        let model = NotesEditorModel(services: lib.services, saveDelay: .zero)
        try await model.load(page)
        return (lib, model, page)
    }

    func apply(_ result: EditResult?, to model: NotesEditorModel) {
        guard let result else { return }
        model.textDidChange(result.apply(to: model.text), selection: result.selection)
    }

    @Test("the editor reads tables, and return adds a row before it continues lists")
    func returnInTable() async throws {
        let (_, model, _) = try await loaded(table)
        #expect(model.document.blocks.map(\.kind) == [.table])
        model.selectionDidChange(model.text.utf16.count..<model.text.utf16.count)
        apply(model.returnKey(), to: model)
        #expect(model.text == table + "\n|  |  |")
        apply(model.returnKey(), to: model)
        #expect(model.text == table + "\n")
    }

    @Test("tables draw as grids unless the focused editor's selection touches them")
    func gridSwitching() async throws {
        let (_, model, _) = try await loaded("intro\n" + table + "\nafter")
        let range = try #require(model.tables.first).range
        #expect(model.gridTables.map(\.ordinal) == [0])  // unfocused, the caret at the start: drawn
        #expect(model.spans.contains { $0.role == NotesRole.tableGrid && $0.range == range })
        model.focusDidChange(true)
        model.selectionDidChange(range.lowerBound + 3..<range.lowerBound + 3)
        #expect(model.gridTables.isEmpty)
        #expect(!model.spans.contains { $0.role == NotesRole.tableGrid })
        model.selectionDidChange(range.upperBound..<range.upperBound)  // the end of the last row is in it
        #expect(model.gridTables.isEmpty)
        model.selectionDidChange(range.upperBound + 1..<range.upperBound + 1)
        #expect(model.gridTables.map(\.table.range) == [range])
        #expect(model.gridTable(at: range.lowerBound + 2)?.ordinal == 0 && model.gridTable(at: 2) == nil)
        model.selectionDidChange(0..<model.text.utf16.count)  // a selection across it
        #expect(model.gridTables.isEmpty)
        model.focusDidChange(false)
        #expect(model.gridTables.isEmpty)  // a selection in it (a find match) shows it without focus too
        model.selectionDidChange(range.lowerBound + 3..<range.lowerBound + 3)
        #expect(model.gridTables.count == 1)  // a caret doesn't
    }

    @Test("the grid's commands: add row and column by ordinal, a cell click's caret, paste")
    func gridCommands() async throws {
        let (_, model, _) = try await loaded(table + "\nafter")
        let end = model.text.utf16.count
        model.selectionDidChange(end..<end)
        apply(model.addRow(toTable: 0), to: model)
        #expect(model.text == table + "\n|  |  |\nafter")
        #expect(model.selection == model.text.utf16.count..<model.text.utf16.count)
        apply(model.addColumn(toTable: 0), to: model)
        #expect(model.tables.first?.columnCount == 3)
        #expect(model.addRow(toTable: 1) == nil && model.addColumn(toTable: -1) == nil)
        // Row 1 is the first body row: "| 1 | 2 |  |", the caret after "2".
        let caret = try #require(model.caret(inTable: 0, row: 1, column: 1))
        #expect(model.document.text[caret - 1..<caret] == "2")
        #expect(model.caret(inTable: 0, row: 9, column: 0) == nil)
        model.selectionDidChange(0..<0)
        let pasted = try #require(model.paste("| x |\n|---|"))
        #expect(pasted.apply(to: model.text).hasPrefix("| x |\n|---|\n\n| a | b |"))
        #expect(model.paste("plain words") == nil)
    }

    @Test("/table inserts a 2×2 table with the caret in its first header cell")
    func slashTable() async throws {
        let (_, model, _) = try await loaded("")
        model.textDidChange("/table", selection: 6..<6)
        #expect(model.slashMenu?.items.first?.id == "table")
        let result = try #require(try await model.confirmSlashMenu())
        let applied = EditResult(edits: [result.edit], selection: result.selection)
        apply(applied, to: model)
        #expect(model.text == "|  |  |\n| --- | --- |\n|  |  |")
        #expect(model.selection == 2..<2)
        #expect(model.tables.first?.columnCount == 2)
    }
}
