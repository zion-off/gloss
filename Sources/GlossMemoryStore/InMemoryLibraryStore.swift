import Foundation
import GlossCore

/// A complete in-memory `LibraryStore`, used by core tests, the CLI tests and SwiftUI
/// previews. Writes run on a copy of the state that replaces the original only when the
/// transaction body succeeds, so failed transactions roll back like SQLite's.
public final class InMemoryLibraryStore: LibraryStore, ChangeFeed, LibraryBackup, Sendable {
    public let origin: String
    private let time: any TimeSource
    private let state: Locked<MemoryState>

    public init(origin: String = "memory", time: any TimeSource = SystemTimeSource()) {
        self.origin = origin
        self.time = time
        self.state = Locked(MemoryState())
    }

    public func read<T: Sendable>(_ work: @escaping @Sendable (any ReadTransaction) throws -> T) async throws -> T {
        let snapshot = state.current
        return try work(MemoryTransaction(state: snapshot, origin: origin, now: time.now()).reading)
    }

    public func write<T: Sendable>(_ work: @escaping @Sendable (any WriteTransaction) throws -> T) async throws -> T {
        try state.withLock { current in
            let transaction = MemoryTransaction(state: current, origin: origin, now: time.now())
            let result = try work(transaction)
            current = transaction.state
            return result
        }
    }

    // MARK: ChangeFeed

    public func latestChangeSequence() async throws -> Int64 {
        state.current.changes.last?.sequence ?? 0
    }

    public func changes(after sequence: Int64, limit: Int) async throws -> [ChangeRecord] {
        Array(state.current.changes.filter { $0.sequence > sequence }.prefix(limit))
    }

    public func trimChanges(before date: Date) async throws {
        state.withLock { $0.changes.removeAll { $0.date < date } }
    }

    // MARK: LibraryBackup

    public func backup(to url: URL) async throws {
        let snapshot = state.current
        let summary = "gloss in-memory library: \(snapshot.documents.count) documents, \(snapshot.pages.count) pages\n"
        try Data(summary.utf8).write(to: url)
    }

    /// Recorded tombstones, for tests.
    public var tombstones: [(entity: String, id: String)] {
        state.current.tombstones.map { ($0.entity, $0.id) }
    }
}

struct MemoryState: Sendable {
    var documents: [DocumentID: Document] = [:]
    var pages: [PageID: Page] = [:]
    var highlights: [HighlightID: Highlight] = [:]
    var linkTargets: [LinkTargetID: LinkTarget] = [:]
    var references: [PageID: Set<ReferenceTarget>] = [:]
    var trash: [TrashEntryID: TrashEntry] = [:]
    var settings: [String: Data] = [:]
    var positions: [DocumentID: ReadingPosition] = [:]
    var fullText: [String: [FullTextEntry]] = [:]
    var covers: [DocumentID: CoverImage] = [:]
    var tombstones: [(entity: String, id: String, date: Date)] = []
    var changes: [ChangeRecord] = []

    static func ftsKey(_ corpus: Corpus, _ owner: String) -> String { corpus.rawValue + "\u{1F}" + owner }
}
