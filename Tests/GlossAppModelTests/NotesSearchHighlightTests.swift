import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossTestSupport

@MainActor
struct NotesSearchHighlightTests {
    let table = "| whale | b |\n| --- | --- |\n| 1 | 2 |"

    @Test("the page's matches follow the text: edits and page switches re-derive them")
    func matchesFollowTheText() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let other = try await lib.services.pages.createSubpage(under: root.id, title: "other")
        try await lib.services.pages.updateBody(other.id, to: "whale here too")
        let model = NotesEditorModel(services: lib.services, saveDelay: .zero)
        try await model.load(root)

        model.setSearch(query: "whale", current: nil)
        model.textDidChange("the whale, big", selection: 9..<9)
        #expect(model.searchRanges == [4..<9])  // shifted with the edit

        // A drawn table's source conceals its matches; the caret inside un-draws it.
        model.textDidChange(table + "\nwhale after", selection: model.text.utf16.count..<model.text.utf16.count)
        #expect(model.searchRanges == [table.utf16.count + 1..<(table.utf16.count + 6)])
        model.focusDidChange(true)
        model.selectionDidChange(1..<1)  // the caret enters the table: it shows as text
        #expect(model.searchRanges.count == 2)  // the table's cell is searchable now too

        // A page switch mid-session derives the new page's matches, not the old page's offsets.
        try await model.load(try #require(try await lib.services.pages.page(other.id)))
        #expect(model.searchRanges == [0..<5])  // "whale" in "whale here too"

        // Ending the session clears them wherever they were.
        model.setSearch(query: nil, current: nil)
        #expect(model.searchRanges.isEmpty && model.searchCurrent == nil)
    }

    @Test("hidden markdown and links never highlight; the current match clamps to the page")
    func concealment() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        try await lib.services.pages.updateBody(root.id, to: "**bold** and [a **bold** link](gloss://page/x)")
        let model = NotesEditorModel(services: lib.services, saveDelay: .zero)
        try await model.load(try #require(try await lib.services.pages.page(root.id)))
        model.setSearch(query: "bold", current: 999..<1002)
        // The plain one, and the one inside the link's label; not the ones hidden as syntax,
        // and not the destination (which contains no match here anyway).
        #expect(model.searchRanges == [2..<6, 18..<22])
        #expect(model.searchCurrent == 46..<46)  // clamped to the page, not crashed
    }
}
