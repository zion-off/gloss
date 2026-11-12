import Foundation
import GlossCore
import GRDB

/// The library in one SQLite file (WAL mode), safe to share between the app and the CLI.
public final class SQLiteLibraryStore: LibraryStore, ChangeFeed, LibraryBackup, Sendable {
    public let origin: String
    public let url: URL?
    let writer: any DatabaseWriter
    private let time: any TimeSource

    /// Opens (creating and migrating if needed) the library at `url`.
    public static func open(at url: URL, origin: String = UUID().uuidString, time: any TimeSource = SystemTimeSource()) throws -> SQLiteLibraryStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        return try SQLiteLibraryStore(writer: pool, url: url, origin: origin, time: time)
    }

    /// A private in-memory library (tests, previews).
    public static func inMemory(origin: String = "memory", time: any TimeSource = SystemTimeSource()) throws -> SQLiteLibraryStore {
        try SQLiteLibraryStore(writer: DatabaseQueue(configuration: configuration()), url: nil, origin: origin, time: time)
    }

    private init(writer: any DatabaseWriter, url: URL?, origin: String, time: any TimeSource) throws {
        self.writer = writer
        self.url = url
        self.origin = origin
        self.time = time
        try writer.read { db in
            guard try SQLiteCapabilities.hasFTS5(db) else {
                throw StoreError.conflict("this SQLite build lacks FTS5, which gloss needs for search")
            }
        }
        try Schema.migrator.migrate(writer)
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        // Another process (the app or the CLI) may hold the write lock briefly.
        configuration.busyMode = .timeout(15)
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return configuration
    }

    /// The blob store kept in the same file.
    public var blobs: SQLiteBlobStore { SQLiteBlobStore(writer: writer, time: time) }

    // MARK: LibraryStore

    public func read<T: Sendable>(_ work: @escaping @Sendable (any ReadTransaction) throws -> T) async throws -> T {
        let origin = origin, now = time.now()
        return try await writer.read { db in
            try work(SQLiteTransaction(db: db, origin: origin, now: now).reading)
        }
    }

    public func write<T: Sendable>(_ work: @escaping @Sendable (any WriteTransaction) throws -> T) async throws -> T {
        let origin = origin, now = time.now()
        return try await writer.write { db in
            try work(SQLiteTransaction(db: db, origin: origin, now: now))
        }
    }

    // MARK: ChangeFeed

    public func latestChangeSequence() async throws -> Int64 {
        try await writer.read { db in try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(seq), 0) FROM changes") ?? 0 }
    }

    public func changes(after sequence: Int64, limit: Int) async throws -> [ChangeRecord] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM changes WHERE seq > ? ORDER BY seq LIMIT ?", arguments: [sequence, limit]).map {
                ChangeRecord(sequence: $0["seq"], entity: $0["entity"], entityID: $0["entity_id"], origin: $0["origin"], date: Columns.date($0, "at"))
            }
        }
    }

    public func trimChanges(before date: Date) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM changes WHERE at < ?", arguments: [Columns.date(date)])
        }
    }

    // MARK: LibraryBackup

    /// Writes a consistent, compacted copy of the library to `url` (which must not exist).
    public func backup(to url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw StoreError.conflict("\(url.lastPathComponent) already exists")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path
        try await writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [path])
        }
    }
}

/// Content-addressed blobs in the library file.
public struct SQLiteBlobStore: BlobStore {
    let writer: any DatabaseWriter
    let time: any TimeSource

    public func put(_ data: Data) async throws -> ContentHash {
        let hash = ContentHash.of(data)
        let now = time.now()
        try await writer.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO blobs (hash, size, data, created_at) VALUES (?, ?, ?, ?)",
                           arguments: [hash.hex, data.count, data, Columns.date(now)])
        }
        return hash
    }

    public func data(for hash: ContentHash) async throws -> Data? {
        try await writer.read { db in try Data.fetchOne(db, sql: "SELECT data FROM blobs WHERE hash = ?", arguments: [hash.hex]) }
    }

    public func contains(_ hash: ContentHash) async throws -> Bool {
        try await writer.read { db in try Bool.fetchOne(db, sql: "SELECT 1 FROM blobs WHERE hash = ?", arguments: [hash.hex]) ?? false }
    }

    public func allHashes() async throws -> Set<ContentHash> {
        try await writer.read { db in Set(try String.fetchAll(db, sql: "SELECT hash FROM blobs").compactMap(ContentHash.init(hex:))) }
    }

    public func delete(_ hash: ContentHash) async throws {
        try await writer.write { db in try db.execute(sql: "DELETE FROM blobs WHERE hash = ?", arguments: [hash.hex]) }
    }
}
