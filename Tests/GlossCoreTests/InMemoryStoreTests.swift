import Foundation
import Testing
@testable import GlossCore
import GlossMemoryStore
import GlossTestSupport

@Suite("in-memory store")
struct InMemoryStoreTests {
    let ids = SequentialIDGenerator()

    func makeDocument() -> Document {
        Document(id: ids.make(), kind: .epub, title: "Slouching", author: "Joan Didion",
                 contentHash: .of(Data("x".utf8)), fileSize: 1, addedAt: .testEpoch, updatedAt: .testEpoch)
    }

    @Test("a failing write rolls back")
    func rollback() async throws {
        let store = InMemoryLibraryStore()
        let document = makeDocument()
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await store.write { tx in
                try tx.documents.insert(document)
                throw Boom()
            }
        }
        let count = try await store.read { try $0.documents.documents(.any).count }
        #expect(count == 0)
    }

    @Test("writes are journaled with the store's origin")
    func journal() async throws {
        let store = InMemoryLibraryStore(origin: "cli")
        let document = makeDocument()
        try await store.write { try $0.documents.insert(document) }
        let changes = try await store.changes(after: 0, limit: 10)
        #expect(changes.map(\.entity) == [ChangeEntity.document])
        #expect(changes.first?.origin == "cli")
        #expect(try await store.latestChangeSequence() == 1)
    }

    @Test("typed settings fall back to defaults and round-trip")
    func settings() async throws {
        let store = InMemoryLibraryStore()
        let key = SettingKey<Int?>("trash.ttlDays", default: 30)
        let codec = SettingsCodec()
        #expect(try await store.read { try codec.value(key, in: $0.settings) } == 30)
        try await store.write { try codec.set(.some(nil), for: key, in: $0.settings, at: .testEpoch) }
        #expect(try await store.read { try codec.value(key, in: $0.settings) } == nil)
        try await store.write { try codec.set(.some(7), for: key, in: $0.settings, at: .testEpoch) }
        #expect(try await store.read { try codec.value(key, in: $0.settings) } == 7)
    }

    @Test("full-text search filters by corpus and document")
    func fullText() async throws {
        let store = InMemoryLibraryStore()
        let a = makeDocument(), b = makeDocument()
        try await store.write { tx in
            try tx.fullText.replaceEntries([FullTextEntry(corpus: .bookText, owner: a.id.stringValue, documentID: a.id, title: "ch 1", body: "the white album")], corpus: .bookText, owner: a.id.stringValue)
            try tx.fullText.replaceEntries([FullTextEntry(corpus: .bookText, owner: b.id.stringValue, documentID: b.id, title: "ch 1", body: "white noise")], corpus: .bookText, owner: b.id.stringValue)
            try tx.fullText.replaceEntries([FullTextEntry(corpus: .notes, owner: "p", documentID: a.id, title: "notes", body: "white")], corpus: .notes, owner: "p")
        }
        let all = try await store.read { try $0.fullText.search(FullTextQuery(text: "white", corpus: .bookText)) }
        #expect(all.count == 2)
        let onlyA = try await store.read { try $0.fullText.search(FullTextQuery(text: "white", corpus: .bookText, documentID: a.id)) }
        #expect(onlyA.map(\.documentID) == [a.id])
    }
}
