import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossTestSupport

@MainActor
struct SearchSessionTests {
    /// A search model over a real library, with a context the test controls. The box is a class
    /// so the contextProvider closure (which can't capture the main-actor test) reads live state.
    final class Box: @unchecked Sendable {
        var value: SearchContext = .home
    }

    @MainActor func harness(lib: TestLibrary = TestLibrary(), context: Box = Box()) -> SearchModel {
        SearchModel(services: lib.services, contextProvider: { [weak context] in context?.value ?? .home })
    }

    func hit(_ title: String) -> SearchHit {
        SearchHit(group: .notes, title: title, subtitle: nil, snippet: Snippet(segments: []),
                  destination: .document(DocumentID(GlossID(high: 1, low: UInt64(title.utf16.count)))))
    }

    @Test("the stepper flattens sections in display order, keeps the current hit, wraps both ways")
    func stepper() {
        var stepper = SearchStepper(sections: [SearchResultSection(group: .notes, hits: [hit("a"), hit("b")]),
                                               SearchResultSection(group: .bookText, hits: [hit("c")])])
        #expect(stepper.hits.map(\.title) == ["a", "b", "c"])
        #expect(stepper.step(by: 1)?.title == "a")  // a first Next starts at the top
        #expect(stepper.step(by: 1)?.title == "b")
        #expect(stepper.step(by: 1)?.title == "c")
        #expect(stepper.step(by: 1)?.title == "a")  // wraps forward
        #expect(stepper.step(by: -1)?.title == "c")  // and back
        #expect(stepper.position?.index == 3 && stepper.position?.count == 3)
        stepper.step(by: -2)
        #expect(stepper.currentHit?.title == "a")  // wraps backwards too
        #expect(stepper.select(at: 0)?.title == "a" && stepper.select(at: 9) == nil)

        // New results keep the current hit when it is still there, else nothing is current.
        stepper.replace(sections: [SearchResultSection(group: .bookText, hits: [hit("x"), hit("a")])])
        #expect(stepper.currentHit?.title == "a" && stepper.count == 2)
        stepper.replace(sections: [SearchResultSection(group: .notes, hits: [hit("x")])])
        #expect(stepper.current == nil && stepper.step(by: 1)?.title == "x")
        var empty = SearchStepper()
        #expect(empty.step(by: 1) == nil)  // nothing to step through
    }

    @Test("results fill the stepper; where they show follows the context")
    func placement() async throws {
        let context = Box()
        let model = harness(context: context)
        let book = DocumentID(GlossID(high: 2, low: 1))
        model.isPresented = true
        #expect(model.showsResultsInSidebar == false)
        #expect(model.showsResultsInMainPane == true)
        context.value = .reader(book)
        #expect(model.showsResultsInSidebar == true)
        #expect(model.showsResultsInMainPane == false)
        #expect(model.showsResults)  // the open field shows the empty search state, not home
    }

    @Test("the session keeps its book: another path to another book ends it, a result doesn't")
    func sessionFollowsTheBook() async throws {
        let context = Box()
        let model = harness(context: context)
        let a = DocumentID(GlossID(high: 2, low: 1)), b = DocumentID(GlossID(high: 2, low: 2))
        model.query = "whale"
        context.value = .reader(a)
        #expect(model.followContextChange(currentDocument: a) == false)  // adopts its book
        #expect(model.sessionDocumentID == a)
        model.sessionMoves(to: b)  // a result opened b
        #expect(model.followContextChange(currentDocument: b) == false)
        #expect(model.hasQuery)
        #expect(model.followContextChange(currentDocument: a) == true)  // a jump back to a
        #expect(!model.hasQuery && model.sessionDocumentID == nil)
        // Without a query there is no session to follow.
        #expect(model.followContextChange(currentDocument: a) == false)
    }

    @Test("a query's results become the stepping list, and dismissing clears it")
    func stepperFollowsResults() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book("Moby")
        try await lib.services.pages.updateBody(root.id, to: "the whale, the white whale")
        let context = Box()
        context.value = .notes(root.documentID)
        let model = harness(lib: lib, context: context)
        #expect(model.scope == .document(root.documentID, [.notes]))  // the default for a notes page
        model.query = "whale"
        await model.settle()
        #expect(model.results.flatMap(\.hits).count >= 1)
        #expect(model.stepper.count == model.results.flatMap(\.hits).count)
        #expect(model.step(by: 1) != nil)
        model.dismiss()
        #expect(model.stepper.count == 0 && model.results.isEmpty)
    }
}

@Test("search scopes say whose text and notes they cover")
func scopePredicates() {
    let book = DocumentID(GlossID(high: 3, low: 1)), other = DocumentID(GlossID(high: 3, low: 2))
    let text = SearchScope.document(book, [.text])
    #expect(text.coversText(of: book) && !text.coversText(of: other) && !text.coversNotes(of: book))
    let both = SearchScope.document(book, [.text, .notes])
    #expect(both.coversText(of: book) && both.coversNotes(of: book) && !both.coversNotes(of: other))
    #expect(SearchScope.allNotes.coversNotes(of: book) && !SearchScope.allNotes.coversText(of: book))
    #expect(!SearchScope.library.coversText(of: book) && !SearchScope.library.coversNotes(of: book))
}
