import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossReaderBridge
import GlossTestSupport

@MainActor
struct SearchSessionDrivingTests {
    @Test("a session highlights what its scope covers, and clearing the query clears them")
    func highlightsFollowTheSession() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book(chapters: ["the whale swims"])
        try await lib.services.pages.updateBody(root.id, to: "whale notes")
        let app = AppModel(services: lib.services)
        let driver = FakeDriver()
        app.reader.attach(driver)
        await app.reader.handle(.ready)

        try await app.workspace.openDocument(book.id)
        try await app.notes.load(try #require(try await lib.services.pages.page(root.id)))
        app.search.resetToDefaultScope()  // the window does this on a context change
        app.search.query = "whale"
        await app.search.settle()
        await app.applySearchHighlights()
        // "this book" (split default) covers the book's text and its notes.
        #expect(app.notes.searchRanges.count == 1)
        #expect(driver.calls.isEmpty)  // the fake engine doesn't take the search capability

        // A scope that covers no book text highlights none of it.
        app.search.setScope(.allNotes)
        await app.search.settle()
        await app.applySearchHighlights()
        #expect(app.notes.searchRanges.count == 1)  // all notes covers this book's
        app.search.setScope(.library)
        await app.search.settle()
        await app.applySearchHighlights()
        #expect(app.notes.searchRanges.isEmpty && app.notes.searchCurrent == nil)

        // Ending the search clears everything on every path through it.
        app.search.setScope(.document(book.id, [.text, .notes]))
        await app.search.settle()
        await app.applySearchHighlights()
        #expect(app.notes.searchRanges.count == 1)
        await app.endSearch()
        #expect(!app.search.hasQuery && app.notes.searchRanges.isEmpty)
    }

    @Test("stepping opens the current hit and keeps the session; the current notes hit is emphasised")
    func stepping() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book(chapters: ["the whale swims"])
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "whale facts")
        try await lib.services.pages.updateBody(child.id, to: "whale again")
        let app = AppModel(services: lib.services)
        let driver = FakeDriver()
        app.reader.attach(driver)
        await app.reader.handle(.ready)
        try await app.workspace.openDocument(book.id)
        try await app.notes.load(try #require(try await lib.services.pages.page(root.id)))
        app.search.resetToDefaultScope()
        app.search.query = "whale"
        await app.search.settle()
        #expect(app.search.stepper.count >= 2)

        await app.stepSearch(by: 1)
        #expect(app.search.hasQuery && app.search.stepper.position != nil)  // the session stays
        let first = app.search.stepper.currentHit
        await app.stepSearch(by: 1)
        #expect(app.search.stepper.currentHit != first)  // it moved
        #expect(app.search.stepper.current == 1)
        await app.stepSearch(by: -1)
        #expect(app.search.stepper.currentHit == first)  // and back

        // A notes hit becomes the page's current highlight (the window loads the page it opens).
        if case .page(let id, _, let match)? = app.search.stepper.currentHit?.destination {
            try await app.notes.load(try #require(try await lib.services.pages.page(id)))
            await app.applySearchHighlights()
            #expect(app.notes.searchCurrent == match)
        }
        // A click on a row is the same as stepping to it.
        await app.openSearchResult(at: 0)
        #expect(app.search.stepper.current == 0)
    }

    @Test("switching books outside the session ends it; a result keeps it")
    func sessionEndsOnForeignSwitch() async throws {
        let lib = TestLibrary()
        let (a, aRoot) = try await lib.book("A", chapters: ["whale one"])
        let (b, _) = try await lib.book("B", chapters: ["whale two"])
        try await lib.services.pages.updateBody(aRoot.id, to: "whale notes")
        let app = AppModel(services: lib.services)
        try await app.workspace.openDocument(a.id)
        try await app.notes.load(try #require(try await lib.services.pages.page(aRoot.id)))
        app.search.resetToDefaultScope()
        app.search.query = "whale"
        await app.search.settle()
        await app.applySearchHighlights()
        #expect(app.notes.searchRanges.count == 1)

        // A result opening book B: the session moves with it.
        app.search.sessionMoves(to: b.id)
        try await app.workspace.openDocument(b.id)
        await app.searchFollowsContext()
        #expect(app.search.hasQuery && app.search.sessionDocumentID == b.id)
        // A jump back to A by any other path ends the session and its highlights.
        try await app.workspace.openDocument(a.id)
        await app.searchFollowsContext()
        #expect(!app.search.hasQuery && app.notes.searchRanges.isEmpty)
    }
}
