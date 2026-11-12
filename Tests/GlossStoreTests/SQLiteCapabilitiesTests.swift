import GRDB
import Testing
@testable import GlossStore

@Suite("SQLite capabilities")
struct SQLiteCapabilitiesTests {
    @Test("the linked SQLite has FTS5")
    func fts5IsAvailable() throws {
        let queue = try DatabaseQueue()
        let available = try queue.read { db in try SQLiteCapabilities.hasFTS5(db) }
        #expect(available)
    }

    @Test("an FTS5 table can be created and queried with diacritic folding")
    func fts5Works() throws {
        let queue = try DatabaseQueue()
        let hits: [String] = try queue.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE t USING fts5(body, tokenize='unicode61 remove_diacritics 2')")
            try db.execute(sql: "INSERT INTO t(body) VALUES ('Café society in Bordeaux')")
            return try String.fetchAll(db, sql: "SELECT snippet(t, 0, '[', ']', '…', 4) FROM t WHERE t MATCH 'cafe'")
        }
        #expect(hits == ["[Café] society in Bordeaux"])
    }
}
