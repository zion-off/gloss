import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossReaderBridge
import GlossTestSupport

@MainActor
@Suite("source list")
struct SidebarTests {
    func locator(_ value: String) -> Locator { Locator(scheme: FakeFormat.scheme, value: value) }

    /// An app with a book open in the reader (through a fake engine) and its sidebar loaded.
    func openApp(_ lib: TestLibrary, toc: [ReaderTocEntry] = []) async throws -> (AppModel, FakeDriver, Document, Page) {
        let (book, root) = try await lib.book("Noces")
        let app = AppModel(services: lib.services)
        let driver = FakeDriver()
        app.reader.attach(driver)
        try await app.workspace.openDocument(book.id)
        await app.reader.openShowing(book, on: driver, toc: toc)
        await app.showBookSidebar()
        return (app, driver, book, root)
    }

    @Test("the library shows until a book opens; opening one selects its notes page")
    func opening() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let app = AppModel(services: lib.services)
        #expect(app.workspace.sidebar == .library(nil))
        #expect(app.workspace.detail == .library(nil))
        try await app.workspace.openDocument(book.id)
        #expect(app.workspace.sidebar == .page(root.id))
        #expect(app.workspace.detail == .book)
        #expect(app.workspace.searchContext == .split(book.id))
    }

    @Test("picking a shelf shows the grid filtered and keeps the book open; picking the book returns")
    func shelves() async throws {
        let lib = TestLibrary()
        let (app, _, book, _) = try await openApp(lib)
        await app.select(.library(.pdfs))
        #expect(app.workspace.detail == .library(.pdfs))
        #expect(app.library.shelf == .pdfs)
        #expect(app.workspace.document?.id == book.id)
        // Searching from the grid is a library search, though a book is open.
        #expect(app.workspace.searchContext == .home)
        await app.select(.trash)
        #expect(app.workspace.detail == .trash)
        await app.select(.book)
        #expect(app.workspace.detail == .book)
        #expect(app.workspace.searchContext == .split(book.id))
    }

    @Test("the book can't be picked when none is open")
    func noBook() async throws {
        let lib = TestLibrary()
        let app = AppModel(services: lib.services)
        await app.select(.book)
        #expect(app.workspace.sidebar == .library(nil))
        await app.select(.highlight(HighlightID(GlossID(high: 9, low: 9))))
        #expect(app.workspace.sidebar == .library(nil))
    }

    @Test("contents nest like the book's, with ids unique even for entries pointing at one place")
    func contentsTree() {
        let toc = [
            ReaderTocEntry(label: "part one", target: locator("p1"), children: [
                ReaderTocEntry(label: "chapter 1", target: locator("c1")),
                ReaderTocEntry(label: "chapter 1 again", target: locator("c1")),
            ]),
            ReaderTocEntry(label: "part two", target: locator("p2")),
        ]
        let nodes = ContentsNode.nodes(from: toc)
        #expect(nodes.map(\.id) == ["0", "1"])
        #expect(nodes[0].children?.map(\.id) == ["0.0", "0.1"])
        #expect(nodes[1].children == nil)  // a leaf has no disclosure triangle
        #expect(ContentsNode.find("0.1", in: nodes)?.label == "chapter 1 again")
        #expect(ContentsNode.find("7", in: nodes) == nil)
    }

    @Test("a contents entry turns the reader to it, showing the reader when hidden")
    func contentsJump() async throws {
        let lib = TestLibrary()
        let toc = [ReaderTocEntry(label: "one", target: locator("p1"), children: [ReaderTocEntry(label: "two", target: locator("c2"))])]
        let (app, driver, _, _) = try await openApp(lib, toc: toc)
        app.workspace.layout = .notesOnly
        await app.select(.contents("0.0"))
        #expect(app.workspace.sidebar == .contents("0.0"))
        #expect(app.workspace.layout == .split)
        #expect(driver.calls.last == .go(locator("c2"), flash: false))
    }

    @Test("highlights list in reading order; picking one goes to its passage and flashes it")
    func highlights() async throws {
        let lib = TestLibrary()
        let (app, driver, book, _) = try await openApp(lib)
        let late = try await lib.services.highlights.add(lib.passage("the sea", at: "late", progression: 0.9), in: book.id)
        let early = try await lib.services.highlights.add(lib.passage("the sun", at: "early", progression: 0.1), in: book.id)
        await app.showBookSidebar()
        #expect(app.bookSidebar.highlights.map(\.id) == [early.id, late.id])

        await app.select(.highlight(late.id))
        #expect(app.workspace.sidebar == .highlight(late.id))
        #expect(driver.calls.last == .go(locator("late"), flash: true))
    }

    @Test("the list follows highlights made and removed in the reader, and drops a removed selection")
    func highlightsFollow() async throws {
        let lib = TestLibrary()
        let (app, driver, book, _) = try await openApp(lib)
        await app.reader.handle(.selectionChanged(lib.passage("light", at: "l1"), anchor: ReaderRect(x: 0, y: 0, width: 1, height: 1)))
        let made = try #require(try await app.reader.highlightSelection(.green))
        #expect(app.bookSidebar.highlights.map(\.id) == [made.id])
        await app.select(.highlight(made.id))
        _ = try await app.reader.deleteHighlight(made.id)
        #expect(app.bookSidebar.highlights.isEmpty)
        #expect(app.workspace.sidebar == .book)
        _ = driver
        _ = book
    }

    @Test("pages form a read-only outline; picking one opens it and shows the notes when hidden")
    func pages() async throws {
        let lib = TestLibrary()
        let (app, _, _, root) = try await openApp(lib)
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "tipasa")
        let untitled = try await lib.services.pages.createSubpage(under: child.id, title: "  ")
        await app.showBookSidebar()
        let outline = try #require(app.bookSidebar.pages.first)
        #expect(outline.id == root.id)
        #expect(outline.children?.map(\.title) == ["tipasa"])
        #expect(outline.children?.first?.children?.map(\.title) == [PageService.untitled])
        #expect(outline.children?.first?.children?.first?.children == nil)

        app.workspace.layout = .readerOnly
        await app.select(.page(untitled.id))
        #expect(app.workspace.page?.id == untitled.id)
        #expect(app.workspace.sidebar == .page(untitled.id))
        #expect(app.workspace.layout == .split)
    }

    @Test("following a link into another book selects its notes page, not the old book's row")
    func crossBook() async throws {
        let lib = TestLibrary()
        let (app, _, _, _) = try await openApp(lib)
        let (other, otherRoot) = try await lib.book("L'Été")
        let h = try await lib.services.highlights.add(lib.passage("x", at: "x"), in: app.workspace.document!.id)
        await app.showBookSidebar()
        await app.select(.highlight(h.id))
        try await app.workspace.openDocument(other.id)
        #expect(app.workspace.sidebar == .page(otherRoot.id))
        await app.showBookSidebar()
        #expect(app.bookSidebar.documentID == other.id)
        #expect(app.bookSidebar.highlights.isEmpty)
    }

    @Test("when the open book is trashed elsewhere, the library shows again")
    func bookTrashed() async throws {
        let lib = TestLibrary()
        let (app, _, book, _) = try await openApp(lib)
        _ = try await lib.services.trash.trash(.document, id: book.id.stringValue)
        let change = ChangeRecord(sequence: 1, entity: ChangeEntity.document, entityID: book.id.stringValue, origin: "cli", date: .testEpoch)
        await app.handleExternalChanges([change])
        #expect(app.workspace.sidebar == .library(nil))
        #expect(app.workspace.detail == .library(nil))
        #expect(app.bookSidebar.documentID == nil)
    }

    @Test("a selected page trashed elsewhere leaves the book selected")
    func pageTrashed() async throws {
        let lib = TestLibrary()
        let (app, _, _, root) = try await openApp(lib)
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "gone soon")
        await app.select(.page(child.id))
        _ = try await lib.services.trash.trash(.page, id: child.id.stringValue)
        let change = ChangeRecord(sequence: 1, entity: ChangeEntity.page, entityID: child.id.stringValue, origin: "cli", date: .testEpoch)
        await app.handleExternalChanges([change])
        #expect(app.workspace.sidebar == .book)
        #expect(app.bookSidebar.pages.first?.children == nil)
    }
}
