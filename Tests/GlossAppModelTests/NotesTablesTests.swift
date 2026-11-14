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

    @Test("resized widths apply to their table, are stored per page and ordinal, and only fit the same column count")
    func columnWidths() async throws {
        let (lib, model, page) = try await loaded(table + "\n\n" + table)
        let key = NotesTableSettings.columnWidths(for: page.id)
        model.resizeColumns(ofTable: 1, to: [0.25, 0.75])
        #expect(model.gridTables.map(\.columnFractions) == [nil, [0.25, 0.75]])
        #expect(model.saveState == .saved)  // view state: the note isn't edited
        #expect(try await lib.services.settings.value(key).isEmpty)  // kept in memory until saved
        model.saveColumnWidths()
        await model.flushColumnWidths()
        #expect(try await lib.services.settings.value(key) == ["1": TableColumnWidths(fractions: [0.25, 0.75])])
        model.resizeColumns(ofTable: 0, to: [1])  // wrong count: ignored
        #expect(model.gridTables[0].columnFractions == nil)

        // Back on the page: applied again; a table that gained a column lays out automatically.
        let other = NotesEditorModel(services: lib.services, saveDelay: .zero)
        try await other.load(page)
        #expect(other.gridTables[1].columnFractions == [0.25, 0.75])
        other.selectionDidChange(other.text.utf16.count..<other.text.utf16.count)
        apply(other.addColumn(toTable: 1), to: other)
        #expect(other.gridTables[1].columnFractions == nil)

        // A reset (and an undo that puts widths back) is stored at once.
        let before = model.columnWidths(ofTable: 1)
        model.setColumnWidths(nil, ofTable: 1)
        await model.flushColumnWidths()
        #expect(model.gridTables[1].columnFractions == nil)
        #expect(try await lib.services.settings.value(key).isEmpty)
        model.setColumnWidths(before, ofTable: 1)
        await model.flushColumnWidths()
        #expect(try await lib.services.settings.value(key) == ["1": TableColumnWidths(fractions: [0.25, 0.75])])
    }

    @Test("loading a note drops stored widths for tables past its table count")
    func pruning() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        try await lib.services.pages.updateBody(root.id, to: table)
        let key = NotesTableSettings.columnWidths(for: root.id)
        let widths = TableColumnWidths(fractions: [0.5, 0.5])
        try await lib.services.settings.set(["0": widths, "3": widths], for: key)
        let model = NotesEditorModel(services: lib.services, saveDelay: .zero)
        try await model.load(try #require(try await lib.services.pages.page(root.id)))
        await model.flushColumnWidths()
        #expect(try await lib.services.settings.value(key) == ["0": widths])
        #expect(model.gridTables.first?.columnFractions == [0.5, 0.5])
    }

    @Test("a resize made while the stored widths load keeps the resize")
    func widthsLoadRace() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        try await lib.services.pages.updateBody(root.id, to: table + "\n\n" + table)
        try await lib.services.settings.set(["1": TableColumnWidths(fractions: [0.5, 0.5])],
                                            for: NotesTableSettings.columnWidths(for: root.id))
        let model = NotesEditorModel(services: lib.services, saveDelay: .zero)
        let loading = Task { try await model.load(try #require(try await lib.services.pages.page(root.id))) }
        // The page's text is installed before `load` finishes; a drag lands in that window.
        var yields = 0
        while model.tables.count < 2, yields < 1000 { await Task.yield(); yields += 1 }
        model.resizeColumns(ofTable: 0, to: [0.25, 0.75])
        try await loading.value
        #expect(model.gridTables[0].columnFractions == [0.25, 0.75])  // the resize, not the stale entry
        #expect(model.gridTables[1].columnFractions == [0.5, 0.5])
    }

    @Test("an external change that removes tables prunes their stored widths")
    func externalPrune() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        try await lib.services.pages.updateBody(root.id, to: table + "\n\n" + table)
        let key = NotesTableSettings.columnWidths(for: root.id)
        try await lib.services.settings.set(["0": TableColumnWidths(fractions: [0.5, 0.5]),
                                             "1": TableColumnWidths(fractions: [0.3, 0.7])], for: key)
        let model = NotesEditorModel(services: lib.services, saveDelay: .zero)
        try await model.load(try #require(try await lib.services.pages.page(root.id)))
        // The cli rewrites the page with just one table.
        try await lib.services.pages.updateBody(root.id, to: table)
        await model.pageChangedExternally()
        await model.flushColumnWidths()
        #expect(model.tables.count == 1)
        #expect(Array((try await lib.services.settings.value(key)).keys) == ["0"])
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
