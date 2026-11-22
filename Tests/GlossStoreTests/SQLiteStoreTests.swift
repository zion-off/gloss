import Foundation
import GRDB
import Testing
import GlossCore
import GlossTestSupport
@testable import GlossStore

@Suite("sqlite store")
struct SQLiteStoreTests {
    let ids = SequentialIDGenerator()

    func document(_ title: String = "Play It as It Lays") -> Document {
        Document(id: ids.make(), kind: .epub, title: title, author: "Joan Didion", contentHash: .of(Data(title.utf8)), fileSize: 42,
                 originalFilename: "play.epub", metadata: DocumentMetadata(language: "en", pageCount: 214, extra: ["k": "v"]),
                 addedAt: .testEpoch, updatedAt: .testEpoch)
    }

    @Test("rows round-trip through every repository")
    func roundTrips() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let doc = document()
        let page = Page(id: ids.make(), documentID: doc.id, parentID: nil, title: "notes", body: "# hi\n\n- [ ] x", position: 0,
                        createdAt: .testEpoch, updatedAt: .testEpoch)
        let passage = Passage(locator: Locator(scheme: LocatorScheme("epubcfi"), value: "epubcfi(/6/4!/4/2,/1:0,/1:5)"), quote: "maria", label: "chapter 1", progression: 0.25)
        let highlight = Highlight(id: ids.make(), documentID: doc.id, passage: passage, color: .blue, createdAt: .testEpoch, updatedAt: .testEpoch)
        let target = LinkTarget(id: ids.make(), documentID: doc.id, passage: passage, createdAt: .testEpoch, updatedAt: .testEpoch, orphanedSince: .testEpoch)
        try await store.write { tx in
            try tx.documents.insert(doc)
            try tx.pages.insert(page)
            try tx.highlights.insert(highlight)
            try tx.linkTargets.insert(target)
            try tx.readingPositions.save(ReadingPosition(documentID: doc.id, locator: passage.locator, progression: 0.5, label: "ch 1", updatedAt: .testEpoch))
            try tx.covers.setDerivedCover(CoverImage(data: Data([1, 2]), mimeType: "image/png"), of: doc.id)
            try tx.references.setReferences([.passage(target.id), .page(page.id)], from: page.id)
        }
        var changed = doc
        changed.trash = TrashStamp(entryID: ids.make(), trashedAt: .testEpoch)
        changed.coverHash = .of(Data([9]))
        let updated = changed
        try await store.write { tx in try tx.documents.update(updated) }
        let (readDoc, readPage, readHighlight, readTarget, position, cover, refs) = try await store.read { tx in
            (try tx.documents.document(doc.id), try tx.pages.page(page.id), try tx.highlights.highlight(highlight.id),
             try tx.linkTargets.linkTarget(target.id), try tx.readingPositions.readingPosition(of: doc.id),
             try tx.covers.derivedCover(of: doc.id), try tx.references.references(from: page.id))
        }
        #expect(readDoc == updated)
        #expect(readPage == page)
        #expect(readHighlight == highlight)
        #expect(readTarget == target)
        #expect(position?.label == "ch 1")
        #expect(cover?.mimeType == "image/png")
        #expect(refs == [.passage(target.id), .page(page.id)])
        let found = try await store.read { try $0.linkTargets.linkTarget(in: doc.id, at: passage.locator) }
        #expect(found?.id == target.id)
        #expect(try await store.read { try $0.documents.referencedBlobHashes() } == [doc.contentHash, updated.coverHash!])
    }

    @Test("a failing transaction rolls back and updating a missing row throws")
    func rollback() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let doc = document()
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await store.write { tx in try tx.documents.insert(doc); throw Boom() }
        }
        #expect(try await store.read { try $0.documents.documents(.any) }.isEmpty)
        await #expect(throws: StoreError.self) { try await store.write { tx in try tx.documents.update(doc) } }
        try await store.write { tx in try tx.documents.insert(doc) }
        await #expect(throws: StoreError.conflict("document \(doc.id)")) { try await store.write { tx in try tx.documents.insert(doc) } }
    }

    @Test("a document's full-text entries read back in the order they were indexed")
    func entriesInOrder() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let a = document("a"), b = document("b")
        let chapters = (0..<5).map { index in
            FullTextEntry(corpus: .bookText, owner: a.id.stringValue, documentID: a.id, locator: Locator(scheme: LocatorScheme("x"), value: "\(index)"),
                          label: "chapter \(index + 1)", title: "chapter \(index + 1)", body: "text \(index)")
        }
        try await store.write { tx in
            try tx.documents.insert(a)
            try tx.documents.insert(b)
            try tx.fullText.replaceEntries([FullTextEntry(corpus: .bookText, owner: b.id.stringValue, documentID: b.id, title: "b", body: "other")],
                                           corpus: .bookText, owner: b.id.stringValue)
            try tx.fullText.replaceEntries(chapters, corpus: .bookText, owner: a.id.stringValue)
            try tx.fullText.replaceEntries([FullTextEntry(corpus: .notes, owner: "p", documentID: a.id, title: "notes", body: "mine")],
                                           corpus: .notes, owner: "p")
        }
        #expect(try await store.read { try $0.fullText.entries(corpus: .bookText, documentID: a.id) } == chapters)
        #expect(try await store.read { try $0.fullText.search(FullTextQuery(text: "text", corpus: .bookText, limit: nil)) }.count == 5)
    }

    @Test("full-text search: prefixes, diacritics, filters, snippets and removal")
    func fullText() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let a = document("a"), b = document("b")
        try await store.write { tx in
            try tx.documents.insert(a)
            try tx.documents.insert(b)
            try tx.fullText.replaceEntries([
                FullTextEntry(corpus: .bookText, owner: a.id.stringValue, documentID: a.id, locator: Locator(scheme: LocatorScheme("x"), value: "1"),
                              label: "chapter 1", title: "chapter 1", body: "The café on the boulevard was empty at dawn."),
            ], corpus: .bookText, owner: a.id.stringValue)
            try tx.fullText.replaceEntries([
                FullTextEntry(corpus: .bookText, owner: b.id.stringValue, documentID: b.id, title: "ch", body: "cafeteria food"),
            ], corpus: .bookText, owner: b.id.stringValue)
        }
        let hits = try await store.read { try $0.fullText.search(FullTextQuery(text: "CAFE boul", corpus: .bookText)) }
        #expect(hits.count == 1)
        #expect(hits[0].label == "chapter 1")
        #expect(hits[0].locator?.value == "1")
        #expect(hits[0].snippet.segments.filter(\.isMatch).map(\.text) == ["café", "boulevard"])
        let both = try await store.read { try $0.fullText.search(FullTextQuery(text: "caf", corpus: .bookText)) }
        #expect(both.count == 2)
        let onlyB = try await store.read { try $0.fullText.search(FullTextQuery(text: "caf", corpus: .bookText, documentID: b.id)) }
        #expect(onlyB.map(\.documentID) == [b.id])
        #expect(try await store.read { try $0.fullText.search(FullTextQuery(text: "\"'()*:^", corpus: .bookText)) }.isEmpty)
        try await store.write { tx in try tx.fullText.removeEntries(corpus: .bookText, documentID: a.id) }
        #expect(try await store.read { try $0.fullText.search(FullTextQuery(text: "caf", corpus: .bookText)) }.count == 1)
        try await store.write { tx in try tx.fullText.removeAllEntries(corpus: .bookText) }
        let leftovers = try await store.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM fts") }
        #expect(leftovers == 0)
    }

    @Test("query building quotes words and makes them prefixes")
    func queryBuilder() {
        #expect(FTSQueryBuilder.build("night boat") == "\"night\"* \"boat\"*")
        #expect(FTSQueryBuilder.build("  ") == nil)
        #expect(FTSQueryBuilder.build("don't") == "\"don\"* \"t\"*")
        #expect(FTSQueryBuilder.snippet(from: "a \u{2}b\u{3} c").segments == [.init(text: "a ", isMatch: false), .init(text: "b", isMatch: true), .init(text: " c", isMatch: false)])
    }

    @Test("blobs are content-addressed and idempotent")
    func blobs() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let blobs = store.blobs
        let data = Data("epub bytes".utf8)
        let first = try await blobs.put(data)
        let second = try await blobs.put(data)
        #expect(first == second)
        #expect(try await blobs.data(for: first) == data)
        #expect(try await blobs.allHashes() == [first])
        try await blobs.delete(first)
        #expect(try await blobs.contains(first) == false)
    }

    @Test("settings round-trip and reset")
    func settings() async throws {
        let store = try SQLiteLibraryStore.inMemory()
        let settings = SettingsService(store: store, time: SystemTimeSource())
        #expect(try await settings.value(TrashSettings.retentionDays) == 30)
        try await settings.set(nil, for: TrashSettings.retentionDays)
        #expect(try await settings.value(TrashSettings.retentionDays) == nil)
        try await settings.reset(TrashSettings.retentionDays)
        #expect(try await settings.value(TrashSettings.retentionDays) == 30)
    }
}

@Suite("sqlite files: sharing, journal, backup")
struct SQLiteFileTests {
    @Test("two stores on one file see each other's writes through the change journal")
    func sharedFile() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("library.sqlite")
        let app = try SQLiteLibraryStore.open(at: url, origin: "app")
        let cli = try SQLiteLibraryStore.open(at: url, origin: "cli")
        let start = try await app.latestChangeSequence()
        let cliLibrary = try SQLiteTestLibrary(store: cli)
        let (document, _) = try await cliLibrary.book("from the cli")
        let changes = try await app.changes(after: start, limit: 100)
        #expect(changes.contains { $0.entity == ChangeEntity.document && $0.entityID == document.id.stringValue && $0.origin == "cli" })
        #expect(try await app.read { try $0.documents.document(document.id) }?.title == "from the cli")
        try await app.trimChanges(before: Date().addingTimeInterval(3600))
        #expect(try await app.changes(after: 0, limit: 10).isEmpty)
    }

    @Test("concurrent writers in two stores never fail")
    func concurrentWriters() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("library.sqlite")
        let a = try SQLiteTestLibrary(store: SQLiteLibraryStore.open(at: url, origin: "a"))
        let b = try SQLiteTestLibrary(store: SQLiteLibraryStore.open(at: url, origin: "b"))
        let (_, root) = try await a.book()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                let library = index.isMultiple(of: 2) ? a : b
                group.addTask { _ = try await library.services.pages.createSubpage(under: root.id, title: "page \(index)") }
            }
            try await group.waitForAll()
        }
        #expect(try await b.services.pages.children(of: root.id).count == 40)
    }

    @Test("reopening runs migrations once and keeps data")
    func reopen() async throws {
        let dir = TemporaryDirectory()
        let url = dir.file("nested/dir/library.sqlite")
        do {
            let library = try SQLiteTestLibrary(store: SQLiteLibraryStore.open(at: url))
            _ = try await library.book("persisted")
        }
        let reopened = try SQLiteLibraryStore.open(at: url)
        #expect(try await reopened.read { try $0.documents.documents(.live) }.map(\.title) == ["persisted"])
    }

    @Test("backups are consistent, standalone copies")
    func backup() async throws {
        let dir = TemporaryDirectory()
        let library = try SQLiteTestLibrary(store: SQLiteLibraryStore.open(at: dir.file("library.sqlite")))
        _ = try await library.book("backed up")
        let copy = dir.file("backup/gloss-backup.sqlite")
        try await library.store.backup(to: copy)
        await #expect(throws: StoreError.self) { try await library.store.backup(to: copy) }
        let restored = try SQLiteLibraryStore.open(at: copy)
        #expect(try await restored.read { try $0.documents.documents(.live) }.map(\.title) == ["backed up"])
        #expect(try await restored.blobs.allHashes().count == 1)
    }

    @Test("library location honours explicit paths, GLOSS_LIBRARY and XDG")
    func location() {
        #expect(LibraryLocation.resolve(explicit: "/tmp/x.sqlite", environment: [:]).path == "/tmp/x.sqlite")
        #expect(LibraryLocation.resolve(environment: ["GLOSS_LIBRARY": "/data/lib.sqlite"]).path == "/data/lib.sqlite")
        #if os(macOS)
        #expect(LibraryLocation.resolve(environment: ["HOME": "/Users/z"]).path == "/Users/z/Library/Application Support/gloss/library.sqlite")
        #else
        #expect(LibraryLocation.resolve(environment: ["HOME": "/home/z"]).path == "/home/z/.local/share/gloss/library.sqlite")
        #expect(LibraryLocation.resolve(environment: ["HOME": "/home/z", "XDG_DATA_HOME": "/xdg"]).path == "/xdg/gloss/library.sqlite")
        #endif
    }
}

@Suite("core scenarios on sqlite")
struct SQLiteScenarioTests {
    @Test("import, search, link, degrade and purge behave as on the in-memory store")
    func scenario() async throws {
        let lib = try SQLiteTestLibrary()
        let (camus, _) = try await lib.book("Camus", chapters: ["the absurd hero", "imagine sisyphus happy"])
        let (_, didionRoot) = try await lib.book("Didion")
        let (page, target, _) = try await lib.services.links.addQuote(of: lib.passage("imagine sisyphus", at: "c1"), in: camus.id, to: didionRoot.id)
        #expect(page.body.contains("gloss://passage/\(target.id)"))
        #expect(try await lib.services.links.linkedPassages(in: camus.id).first?.pages.map(\.id) == [didionRoot.id])
        let hits = try await lib.services.search.search("sisyph", in: .document(camus.id, [.text]))
        #expect(hits.first?.hits.first?.title == "chapter 2")
        let notes = try await lib.services.search.search("sisyph", in: .allNotes)
        #expect(notes.first?.hits.first?.destination == .page(didionRoot.id, didionRoot.documentID, match: 10..<18))
        let entry = try await lib.services.trash.trash(.document, id: camus.id.stringValue)
        try await lib.services.trash.purge(entry.id)
        #expect(try await lib.services.pages.page(didionRoot.id)?.body == "> imagine sisyphus ↗\n")
        #expect(try await lib.services.blobCollector.collect() == 1)
        let tombstones = try await lib.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM tombstones WHERE entity = 'document'") }
        #expect(tombstones == 1)
    }

    @Test("orphan sweeps and rebuilds work on sqlite")
    func maintenance() async throws {
        let lib = try SQLiteTestLibrary()
        let (book, root) = try await lib.book()
        let target = try await lib.services.links.target(for: lib.passage("q", at: "c"), in: book.id)
        try await lib.services.pages.updateBody(root.id, to: "[q](gloss://passage/\(target.id))")
        try await lib.store.write { tx in try tx.references.removeAllReferences() }
        try await lib.services.rebuilder.rebuildAll()
        #expect(try await lib.services.links.linkedPassages(in: book.id).count == 1)
        try await lib.services.pages.updateBody(root.id, to: "")
        lib.clock.advance(by: LinkMaintenance.orphanGracePeriod + 1)
        try await lib.services.performMaintenance()
        #expect(try await lib.services.links.linkTarget(target.id) == nil)
    }
}
