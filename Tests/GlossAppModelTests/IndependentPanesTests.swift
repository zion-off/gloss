import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossReaderBridge
import GlossTestSupport

/// Each pane moves on its own. A link changes the pane it points into, so the reader and
/// the notes can show different books (brief 15: "following a cross-book link swaps the book
/// pane"; every pane has its own back and forward).
@MainActor
@Suite("independent panes")
struct IndependentPanesTests {
    /// Book A open with its notes, and book B holding a linkable passage.
    func twoBooks(_ lib: TestLibrary) async throws -> (app: AppModel, a: Document, aRoot: Page, b: Document, bRoot: Page, target: LinkTarget) {
        let (a, aRoot) = try await lib.book("A")
        let (b, bRoot) = try await lib.book("B")
        let (_, target, _) = try await lib.services.links.addQuote(of: lib.passage("call me ishmael", at: "c"), in: b.id, to: bRoot.id)
        let app = AppModel(services: lib.services)
        try await app.workspace.openDocument(a.id)
        return (app, a, aRoot, b, bRoot, target)
    }

    @Test("a passage link into another book swaps the reader and keeps the notes")
    func passageLinkKeepsNotes() async throws {
        let lib = TestLibrary()
        let (app, a, aRoot, b, _, target) = try await twoBooks(lib)
        let outcome = await app.follow(.passage(target.id))
        #expect(outcome == .routed(.passage(target.id, b.id)))
        #expect(app.workspace.document?.id == b.id)
        #expect(app.workspace.page?.id == aRoot.id)
        #expect(app.workspace.readerFocus?.locator == target.passage.locator)
        // The reader has somewhere to go back to; the notes didn't move.
        #expect(app.workspace.canGoBackInReader)
        #expect(!app.workspace.canGoBackInNotes)
        #expect(app.workspace.sidebar == .page(aRoot.id))
        #expect(app.bookSidebarSubjects == BookSidebarSubjects(reader: b.id, notes: a.id))
    }

    @Test("following the same passage link again sends the reader there again")
    func samePassageLinkAgain() async throws {
        let lib = TestLibrary()
        let (app, _, _, _, _, target) = try await twoBooks(lib)
        await app.follow(.passage(target.id))
        let focus = app.workspace.readerFocus
        let request = app.workspace.readerFocusRequest
        // The reader scrolled away meanwhile; the same link is the same focus, and a new request.
        await app.follow(.passage(target.id))
        #expect(app.workspace.readerFocus == focus)
        #expect(app.workspace.readerFocusRequest == request + 1)
    }

    @Test("reader back and forward move only the reader")
    func readerHistoryIsTheReaders() async throws {
        let lib = TestLibrary()
        let (app, a, aRoot, b, _, target) = try await twoBooks(lib)
        await app.follow(.passage(target.id))
        try await app.workspace.goBackInReader()
        #expect(app.workspace.document?.id == a.id)
        #expect(app.workspace.page?.id == aRoot.id)
        try await app.workspace.goForwardInReader()
        #expect(app.workspace.document?.id == b.id)
        #expect(app.workspace.page?.id == aRoot.id)
        #expect(!app.workspace.canGoBackInNotes)
    }

    @Test("notes back and forward move only the notes, even across books")
    func notesHistoryIsTheNotes() async throws {
        let lib = TestLibrary()
        let (app, _, aRoot, b, bRoot, target) = try await twoBooks(lib)
        await app.follow(.passage(target.id))  // reader: B, notes: A
        try await app.workspace.openPage(bRoot.id)  // a page link in the notes
        #expect(app.workspace.page?.id == bRoot.id)
        try await app.workspace.goBackInNotes()
        #expect(app.workspace.page?.id == aRoot.id)
        #expect(app.workspace.document?.id == b.id)
        #expect(app.workspace.sidebar == .page(aRoot.id))
    }

    @Test("a book link in the notes swaps only the reader")
    func bookLinkKeepsNotes() async throws {
        let lib = TestLibrary()
        let (app, _, aRoot, b, _, _) = try await twoBooks(lib)
        app.workspace.layout = .notesOnly
        await app.follow(.document(b.id))
        #expect(app.workspace.document?.id == b.id)
        #expect(app.workspace.page?.id == aRoot.id)
        #expect(app.workspace.layout == .split)  // the reader shows what the link swapped in
    }

    @Test("a marker click opens a note from another book's pages and keeps the reader on the passage")
    func markerKeepsReader() async throws {
        let lib = TestLibrary()
        let (app, _, aRoot, b, _, target) = try await twoBooks(lib)
        let page = try await lib.services.pages.createSubpage(under: aRoot.id, title: "whales")
        try await app.workspace.openDocument(b.id)
        await app.reader.openNote(page.id, 3..<9)
        #expect(app.workspace.page?.id == page.id)
        #expect(app.workspace.document?.id == b.id)
        #expect(app.workspace.pendingNoteReveal == 3..<9)
        _ = target
    }

    @Test("picking a page in the outline moves only the notes")
    func outlineKeepsReader() async throws {
        let lib = TestLibrary()
        let (app, _, aRoot, b, _, target) = try await twoBooks(lib)
        let page = try await lib.services.pages.createSubpage(under: aRoot.id, title: "whales")
        await app.follow(.passage(target.id))
        await app.select(.page(page.id))
        #expect(app.workspace.page?.id == page.id)
        #expect(app.workspace.document?.id == b.id)
    }

    @Test("a book-text search hit into another book moves only the reader")
    func searchHitKeepsNotes() async throws {
        let lib = TestLibrary()
        let (app, a, aRoot, b, _, target) = try await twoBooks(lib)
        await app.follow(.passage(target.id))  // reader: B, notes: A
        // A hit in the book the reader already left for — the case that used to drag the notes.
        let hit = SearchModel.Selection.bookText(b.id, locator: Locator(scheme: FakeFormat.scheme, value: "hit"), matchText: "whale")
        await app.reveal(hit)
        #expect(app.workspace.document?.id == b.id)
        #expect(app.workspace.page?.id == aRoot.id)  // the notes stay on A's page
        _ = a
    }

    @Test("a jump from outside the panes brings the other pane along")
    func openBringsTheOtherPane() async throws {
        let lib = TestLibrary()
        let (app, a, aRoot, b, bRoot, target) = try await twoBooks(lib)
        await app.open(.passage(target.id))
        #expect(app.workspace.document?.id == b.id)
        #expect(app.workspace.page?.id == bRoot.id)
        await app.open(.page(aRoot.id))
        #expect(app.workspace.document?.id == a.id)
        #expect(app.workspace.page?.id == aRoot.id)
        await app.open(.document(b.id))
        #expect(app.workspace.page?.id == bRoot.id)
    }

    @Test("a pane never stays empty next to a book")
    func noEmptyPane() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let page = try await lib.services.pages.createSubpage(under: root.id, title: "deep")
        // A page with no book open brings its book…
        let workspace = WorkspaceModel(services: lib.services, persistLayoutSetting: false)
        try await workspace.openPage(page.id)
        #expect(workspace.document?.id == book.id)
        #expect(workspace.detail == .book)
        // …and a book with no page shown brings its main page.
        let other = WorkspaceModel(services: lib.services, persistLayoutSetting: false)
        try await other.showBook(book.id)
        #expect(other.page?.id == root.id)
    }

    @Test("moving the reader drops a selection that belonged to the previous book")
    func staleSelection() async throws {
        let lib = TestLibrary()
        let (app, a, aRoot, _, _, target) = try await twoBooks(lib)
        let highlight = try await lib.services.highlights.add(lib.passage("x", at: "x"), in: a.id)
        await app.showBookSidebar()
        await app.select(.highlight(highlight.id))
        #expect(app.workspace.sidebar == .highlight(highlight.id))
        await app.follow(.passage(target.id))
        #expect(app.workspace.sidebar == .page(aRoot.id))
    }

    @Test("the source list shows the reader's highlights and the notes' pages, naming the notes' book")
    func sidebarFollowsBothPanes() async throws {
        let lib = TestLibrary()
        let (app, a, aRoot, b, _, target) = try await twoBooks(lib)
        let inB = try await lib.services.highlights.add(lib.passage("y", at: "y"), in: b.id)
        _ = try await lib.services.highlights.add(lib.passage("x", at: "x"), in: a.id)
        await app.follow(.passage(target.id))
        await app.showBookSidebar()
        #expect(app.bookSidebar.documentID == b.id)
        #expect(app.bookSidebar.highlights.map(\.id) == [inB.id])
        #expect(app.bookSidebar.notesDocumentID == a.id)
        #expect(app.bookSidebar.pages.first?.id == aRoot.id)
        #expect(app.bookSidebar.notesTitle == "A")
        // Choosing a book brings its notes along; the section is one book again.
        try await app.workspace.openDocument(b.id)
        await app.showBookSidebar()
        #expect(app.bookSidebar.notesDocumentID == b.id)
        #expect(app.bookSidebar.notesTitle == nil)
    }

    @Test("⌘K links words in one book's notes to a passage in another, and the marker shows there")
    func crossBookLink() async throws {
        let lib = TestLibrary()
        let (a, aRoot) = try await lib.book("A")
        let (b, bRoot) = try await lib.book("B")
        let (_, existing, _) = try await lib.services.links.addQuote(of: lib.passage("loomings", at: "c0"), in: b.id, to: bRoot.id)
        let app = AppModel(services: lib.services)
        let driver = FakeDriver()
        app.reader.attach(driver)
        try await app.workspace.openDocument(a.id)
        await app.follow(.passage(existing.id))  // the reader moves to B, the notes stay on A
        await app.reader.openShowing(b, on: driver)
        try await app.notes.load(aRoot)
        app.notes.textDidChange("see the whale", selection: 8..<13)
        await app.reader.handle(.selectionChanged(lib.passage("the whale", at: "cfi-9"), anchor: ReaderRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(app.linkAvailability == .ready)

        let edit = try await app.linkSelectionToPassage()
        let linked = edit.apply(to: app.notes.text)
        let id = try #require(linked.split(separator: "/").last?.split(separator: ")").first.map(String.init))
        #expect(try await lib.services.links.linkTarget(try #require(LinkTargetID(id)))?.documentID == b.id)

        try await lib.services.pages.updateBody(aRoot.id, to: linked)
        await app.linking.didSaveLinkedPage()
        #expect(driver.lastAnnotations?.markers.contains { $0.id.stringValue == id } == true)
    }

    @Test("a link that leads nowhere says why")
    func problems() async throws {
        let (book, _) = try await TestLibrary().book()
        #expect(RouteOutcome.routed(.document(book.id)).problem == nil)
        #expect(RouteOutcome.inTrash("moby dick").problem?.title == "“moby dick” is in the trash")
        #expect(RouteOutcome.inTrash("  ").problem?.title == "“\(PageService.untitled)” is in the trash")
        #expect(RouteOutcome.missing.problem?.title == "this link leads nowhere")
    }
}
