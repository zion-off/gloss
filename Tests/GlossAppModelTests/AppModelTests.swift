
/// A temporary directory removed when deinitialised.
final class TempDir: @unchecked Sendable {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-appmodel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}
import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossMemoryStore
import GlossTestSupport
import GlossReaderBridge

@MainActor
struct WorkspaceModelTests {
    @Test("opening a book opens its root notes page and pushes history")
    func openDocument() async throws {
        let lib = TestLibrary()
        let (a, aRoot) = try await lib.book("A")
        let (b, bRoot) = try await lib.book("B")
        let workspace = WorkspaceModel(services: lib.services)
        try await workspace.openDocument(a.id)
        #expect(workspace.document?.id == a.id)
        #expect(workspace.page?.id == aRoot.id)
        try await workspace.openDocument(b.id)
        #expect(workspace.page?.id == bRoot.id)
        #expect(workspace.canGoBackInReader)
        try await workspace.goBackInReader()
        #expect(workspace.document?.id == a.id)
        try await workspace.goForwardInReader()
        #expect(workspace.document?.id == b.id)
    }

    @Test("opening a page from another book brings the book along")
    func openPageAcrossBooks() async throws {
        let lib = TestLibrary()
        let (a, _) = try await lib.book("A")
        let (b, bRoot) = try await lib.book("B")
        let page = try await lib.services.pages.createSubpage(under: bRoot.id, title: "deep")
        let workspace = WorkspaceModel(services: lib.services)
        try await workspace.openDocument(a.id)
        try await workspace.openPage(page.id)
        #expect(workspace.document?.id == b.id)
        #expect(workspace.page?.id == page.id)
        try await workspace.goBackInNotes()
        #expect(workspace.page?.id == bRoot.id)
        _ = a
    }

    @Test("passages focus the reader and keep a pending passage for the engine")
    func openPassage() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let (_, target, _) = try await lib.services.links.addQuote(of: lib.passage("quote", at: "c"), in: book.id, to: root.id)
        let workspace = WorkspaceModel(services: lib.services)
        try await workspace.openPassage(target.id)
        #expect(workspace.document?.id == book.id)
        #expect(workspace.pendingPassage == target.id)
        #expect(workspace.readerFocus?.locator == Locator(scheme: FakeFormat.scheme, value: "c"))
    }

    @Test("refresh drops trashed pages and history pointing at them")
    func refresh() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "child")
        let workspace = WorkspaceModel(services: lib.services)
        try await workspace.openPage(child.id)
        try await workspace.openPage(root.id)
        _ = try await lib.services.trash.trash(.page, id: child.id.stringValue)
        await workspace.refresh()
        #expect(workspace.page?.id == root.id)
        try await workspace.goBackInNotes()
        #expect(workspace.page?.id == root.id) // the trashed page is gone from history
        _ = book
    }

    @Test("the search context follows the layout, and the layout persists")
    func contextAndLayout() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book()
        let workspace = WorkspaceModel(services: lib.services)
        #expect(workspace.searchContext == .home)
        try await workspace.openDocument(book.id)
        workspace.layout = .readerOnly
        #expect(workspace.searchContext == .reader(book.id))
        workspace.layout = .notesOnly
        #expect(workspace.searchContext == .notes(book.id))
        workspace.layout = .split
        #expect(workspace.searchContext == .split(book.id))
        await workspace.flushLayoutPersistence()

        let fresh = WorkspaceModel(services: lib.services)
        await fresh.loadPersistedLayout()
        #expect(fresh.layout == .split)
        workspace.layout = .readerOnly
        await workspace.flushLayoutPersistence()
        await fresh.loadPersistedLayout()
        #expect(fresh.layout == .readerOnly)
    }
}

@MainActor
struct RoutingTests {
    @Test("links route to books, pages and passages; dead and trashed ones say so")
    func routing() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book("Camus")
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "sub")
        let (_, target, _) = try await lib.services.links.addQuote(of: lib.passage("q", at: "c"), in: book.id, to: root.id)
        let app = AppModel(services: lib.services)

        #expect(await app.follow(GlossLink.document(book.id)) == .routed(.document(book.id)))
        #expect(app.workspace.document?.id == book.id)
        #expect(await app.follow(GlossLink.page(child.id)) == .routed(.page(child.id, book.id)))
        #expect(app.workspace.page?.id == child.id)
        #expect(await app.follow(GlossLink.passage(target.id)) == .routed(.passage(target.id, book.id)))
        #expect(app.workspace.pendingPassage == target.id)

        let stranger = PageID(GlossID(high: 9, low: 9))
        #expect(await app.follow(GlossLink.page(stranger)) == .missing)
        _ = try await lib.services.trash.trash(.page, id: child.id.stringValue)
        #expect(await app.follow(GlossLink.page(child.id)) == .inTrash("sub"))
    }

    @Test("following a link reveals the pane it needs")
    func layoutSwitch() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let app = AppModel(services: lib.services)
        app.workspace.layout = .readerOnly
        _ = await app.follow(GlossLink.page(root.id))
        #expect(app.workspace.layout.showsNotes)
        app.workspace.layout = .notesOnly
        _ = await app.follow(GlossLink.document(book.id))
        #expect(app.workspace.layout.showsReader)
    }
}

@MainActor
struct LibraryAndTrashModelTests {
    @Test("the library lists, sorts, shelves and imports with progress")
    func library() async throws {
        let lib = TestLibrary()
        let model = LibraryModel(services: lib.services)
        _ = try await lib.book("Alpha", author: "B")
        lib.clock.advance(by: 1)
        _ = try await lib.book("Beta", author: "A")
        await model.reload()
        #expect(model.entries.map(\.document.title) == ["Beta", "Alpha"])
        model.sort = .title
        await model.settle()
        #expect(model.entries.map(\.document.title) == ["Alpha", "Beta"])
        #expect(model.availableShelves == [.books])

        let directory = TempDir()
        let file = directory.file("Camus.fake")
        try FakeFormat.file(title: "The Fall").write(to: file)
        let imported = await model.importFiles(at: [file])
        #expect(imported.map(\.title) == ["The Fall"])
        #expect(model.lastImportedIDs == imported.map(\.id))
        #expect(model.importing == false)
        #expect(model.importStatus == nil)
        // A duplicate is reported, not imported twice.
        _ = await model.importFiles(at: [file])
        #expect(try await lib.services.library.entries().count == 3)
    }

    @Test("folders expand to their books, sorted")
    func folderExpansion() async throws {
        let directory = TempDir()
        let nested = directory.url.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FakeFormat.file(title: "One").write(to: directory.file("b.fake"))
        try FakeFormat.file(title: "Two").write(to: nested.appendingPathComponent("a.epub"))
        try Data("junk".utf8).write(to: directory.file("notes.txt"))
        try FakeFormat.file(title: "Hidden").write(to: directory.file(".hidden.fake"))
        let files = ImportCandidates.expand(directory.url, supportedExtensions: ["fake", "epub"])
        #expect(files.map(\.lastPathComponent) == ["b.fake", "a.epub"])  // depth-first, sorted per directory
    }

    @Test("the trash lists items with expiry and restores them")
    func trash() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "gone")
        let entry = try await lib.services.trash.trash(.page, id: child.id.stringValue)
        let model = TrashModel(services: lib.services)
        await model.reload()
        #expect(model.items.map(\.entry.id) == [entry.id])
        #expect(model.items.first?.entry.title == "gone")
        #expect(model.retentionDays == 30)
        #expect(model.items.first?.expiresAt != nil)
        await model.setRetention(days: nil)
        #expect(model.retentionDays == nil)
        #expect(model.items.first?.expiresAt == nil)
        await model.restore(entry.id)
        #expect(model.items.isEmpty)
        #expect(try await lib.services.pages.page(child.id)?.trash == nil)
        _ = book
    }
}

@MainActor
struct SearchAndSwitcherTests {
    @Test("search scopes follow the workspace and results group by source")
    func search() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book(chapters: ["the whale swims"])
        try await lib.services.pages.updateBody(root.id, to: "notes about the whale")
        let app = AppModel(services: lib.services)
        try await app.workspace.openDocument(book.id)
        app.search.setScope(.allNotes)
        app.search.query = "whale"
        await app.search.settle()
        #expect(app.search.results.map(\.group) == [.notes])
        app.search.setScope(.document(book.id, [.text, .notes]))
        await app.search.settle()
        #expect(app.search.results.map(\.group) == [.notes, .bookText])
        let section = try #require(app.search.results.first)
        let hit = try #require(section.hits.first)
        #expect(SearchModel.Hit(hit: hit, section: section.id).selection == .page(root.id, book.id, match: 16..<21))
        app.search.query = "   "
        await app.search.settle()
        #expect(app.search.results.isEmpty)
        #expect(!app.search.isSearching)
    }

    @Test("scope options follow the open context")
    func scopes() async throws {
        let lib = TestLibrary()
        let app = AppModel(services: lib.services)
        #expect(app.search.scopeOptions.map(\.title) == ["library", "all notes"])
        let (book, _) = try await lib.book()
        try await app.workspace.openDocument(book.id)
        app.workspace.layout = .readerOnly
        #expect(app.search.scopeOptions.first?.title == "this book's text")
        app.search.resetToDefaultScope()
        #expect(app.search.scope == .document(book.id, [.text]))
    }

    @Test("the quick switcher mixes books and pages")
    func switcher() async throws {
        let lib = TestLibrary()
        let (a, _) = try await lib.book("Moby-Dick")
        let (b, bRoot) = try await lib.book("Middlemarch")
        try await lib.services.pages.updateBody(bRoot.id, to: "moby appears here")
        let model = QuickSwitcherModel(services: lib.services)
        await model.search("moby")
        #expect(model.items.first?.kind == .document)
        #expect(model.items.first?.documentID == a.id)
        #expect(model.items.count == 3)  // the book, its root page (title match) and the page that mentions it
        #expect(model.items.last?.isPage == true)
        #expect(model.items.last?.documentID == b.id)
        await model.search("")
        #expect(model.items.isEmpty)
    }
}

@MainActor
struct ExternalChangeTests {
    /// A canned feed for driving the monitor deterministically.
    final class StubFeed: ChangeFeed, @unchecked Sendable {
        let origin = "app"
        var records: [ChangeRecord] = []
        func latestChangeSequence() async throws -> Int64 { records.last?.sequence ?? 0 }
        func changes(after sequence: Int64, limit: Int) async throws -> [ChangeRecord] {
            Array(records.filter { $0.sequence > sequence }.prefix(limit))
        }
        func trimChanges(before date: Date) async throws {}
    }

    @Test("the monitor reports other processes' writes and skips its own")
    func monitor() async throws {
        let feed = StubFeed()
        var received: [[ChangeRecord]] = []
        let monitor = await ExternalChangeMonitor(feed: feed) { changes in
            received.append(changes)
        }
        #expect(await monitor.poll().isEmpty)
        let mine = ChangeRecord(sequence: 1, entity: ChangeEntity.page, entityID: "x", origin: "app", date: .testEpoch)
        let theirs = ChangeRecord(sequence: 2, entity: ChangeEntity.document, entityID: "y", origin: "cli", date: .testEpoch)
        feed.records = [mine, theirs]
        let changes = await monitor.poll()
        #expect(changes.map(\.origin) == ["cli"])
        #expect(received.count == 1)
        #expect(await monitor.poll().isEmpty)
    }

    @Test("the app reloads library, trash and workspace when the cli writes")
    func appHandlesChanges() async throws {
        let lib = TestLibrary()
        let app = AppModel(services: lib.services)
        let (book, root) = try await lib.book("External")
        try await app.workspace.openDocument(book.id)
        #expect(app.workspace.page?.body.isEmpty == true)

        // The "cli" edits the page behind the app's back.
        try await lib.services.pages.updateBody(root.id, to: "fresh ink")
        let change = ChangeRecord(sequence: 1, entity: ChangeEntity.page, entityID: root.id.stringValue, origin: "cli", date: .testEpoch)
        await app.handleExternalChanges([change])
        // The workspace reloaded the page from the store.
        #expect(app.workspace.page?.body == "fresh ink")
    }
}


@MainActor
struct RaceTests {
    @Test("rapid layout changes persist the last one")
    func layoutRace() async throws {
        let lib = TestLibrary()
        let workspace = WorkspaceModel(services: lib.services)
        for layout in [SplitLayout.readerOnly, .notesOnly, .split, .readerOnly, .notesOnly] { workspace.layout = layout }
        await workspace.flushLayoutPersistence()
        #expect(try await lib.services.settings.value(WorkspaceSettings.layout) == .notesOnly)
    }

    @Test("rapid sort changes show the last sort")
    func sortRace() async throws {
        let lib = TestLibrary()
        _ = try await lib.book("Beta", author: "A")
        lib.clock.advance(by: 1)
        _ = try await lib.book("Alpha", author: "B")
        let model = LibraryModel(services: lib.services)
        for sort in [LibrarySort.author, .title, .dateAdded, .author, .title] { model.sort = sort }
        await model.settle()
        #expect(model.entries.map(\.document.title) == ["Alpha", "Beta"])
    }
}

@MainActor
struct ReviewOneAppModelTests {
    final class PagedFeed: ChangeFeed, @unchecked Sendable {
        let origin = "app"
        var records: [ChangeRecord] = []
        /// Rows that "arrive" while a poll is running (after its first query).
        var lateArrivals: [ChangeRecord] = []
        func latestChangeSequence() async throws -> Int64 { records.last?.sequence ?? 0 }
        func changes(after sequence: Int64, limit: Int) async throws -> [ChangeRecord] {
            let batch = Array(records.filter { $0.sequence > sequence }.prefix(limit))
            if !lateArrivals.isEmpty { records += lateArrivals; lateArrivals = [] }
            return batch
        }
        func trimChanges(before date: Date) async throws {}
    }

    func record(_ sequence: Int64) -> ChangeRecord {
        ChangeRecord(sequence: sequence, entity: ChangeEntity.page, entityID: "p\(sequence)", origin: "cli", date: .testEpoch)
    }

    @Test("polling drains more than one page of changes and never skips late rows")
    func monitorPaging() async throws {
        let feed = PagedFeed()
        let monitor = await ExternalChangeMonitor(feed: feed) { _ in }
        feed.records = (1...1_234).map(record)
        #expect(await monitor.poll().count == 1_234)
        feed.records.append(record(1_235))
        feed.lateArrivals = [record(1_236)]
        #expect(await monitor.poll().map(\.sequence) == [1_235])
        #expect(await monitor.poll().map(\.sequence) == [1_236])  // the row that landed mid-poll
        #expect(await monitor.poll().isEmpty)
    }

    @Test("refresh keeps forward history and clears the focus of a trashed book")
    func refreshKeepsForwardHistory() async throws {
        let lib = TestLibrary()
        let (a, _) = try await lib.book("A")
        let (b, _) = try await lib.book("B")
        let (c, _) = try await lib.book("C")
        let workspace = WorkspaceModel(services: lib.services, persistLayoutSetting: false)
        try await workspace.openDocument(a.id)
        try await workspace.openDocument(b.id)
        try await workspace.openDocument(c.id)
        try await workspace.goBackInReader()
        try await workspace.goBackInReader()
        #expect(workspace.document?.id == a.id)
        await workspace.refresh()
        #expect(workspace.canGoForwardInReader)  // nothing gone, nothing dropped

        _ = try await lib.services.trash.trash(.document, id: a.id.stringValue)
        await workspace.refresh()
        #expect(workspace.document == nil)
        #expect(workspace.page == nil)
        #expect(workspace.readerFocus?.documentID != a.id)
        #expect(workspace.canGoForwardInReader || workspace.canGoBackInReader)
        #expect(!workspace.readerHistory.backStack.contains { $0.documentID == a.id })
    }

    @Test("the reader closes a book trashed from outside, and reopens after an engine reload")
    func readerLifecycle() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book()
        let app = AppModel(services: lib.services)
        let first = FakeDriver()
        app.reader.attach(first)
        await app.reader.handle(.ready)
        await app.reader.open(book)
        await app.reader.handle(.relocated(ReaderLocation(locator: Locator(scheme: FakeFormat.scheme, value: "here"),
                                                          progression: 0.3, label: nil, progressText: "")))
        // The web view crashed and was recreated: the new engine reopens at the same place.
        let second = FakeDriver()
        app.reader.attach(second)
        await app.reader.handle(.ready)
        #expect(second.calls.first == .open(book.id, Locator(scheme: FakeFormat.scheme, value: "here")))

        _ = try await lib.services.trash.trash(.document, id: book.id.stringValue)
        let change = ChangeRecord(sequence: 1, entity: ChangeEntity.document, entityID: book.id.stringValue, origin: "cli", date: .testEpoch)
        await app.handleExternalChanges([change])
        #expect(app.reader.document == nil)
        #expect(app.reader.location == nil)
    }

    @Test("trashed pages name their book")
    func trashBookTitles() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book("Noces")
        let page = try await lib.services.pages.createSubpage(under: root.id, title: "tipasa")
        _ = try await lib.services.trash.trash(.page, id: page.id.stringValue)
        let (other, _) = try await lib.book("Exile")
        _ = try await lib.services.trash.trash(.document, id: other.id.stringValue)
        let model = TrashModel(services: lib.services)
        await model.reload()
        let byTitle = Dictionary(uniqueKeysWithValues: model.items.map { ($0.title, $0.documentTitle) })
        #expect(byTitle["tipasa"] == .some("Noces"))
        #expect(byTitle["Exile"] == .some(nil))
        _ = book
    }
}
