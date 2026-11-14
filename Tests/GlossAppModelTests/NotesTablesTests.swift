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
}
