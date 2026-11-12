import Foundation

/// The library database. All reads and writes go through short synchronous transactions so
/// multi-entity changes (trash cascades, imports, link maintenance) are atomic.
///
/// Implementations: `SQLiteLibraryStore` (GlossStore) and `InMemoryLibraryStore`
/// (GlossMemoryStore). The core never sees a database library.
public protocol LibraryStore: Sendable {
    func read<T: Sendable>(_ work: @escaping @Sendable (any ReadTransaction) throws -> T) async throws -> T
    func write<T: Sendable>(_ work: @escaping @Sendable (any WriteTransaction) throws -> T) async throws -> T
}

/// Read-only view of the library inside one transaction.
public protocol ReadTransaction {
    var documents: any DocumentReading { get }
    var pages: any PageReading { get }
    var highlights: any HighlightReading { get }
    var linkTargets: any LinkTargetReading { get }
    var references: any ReferenceReading { get }
    var trash: any TrashReading { get }
    var settings: any SettingsReading { get }
    var readingPositions: any ReadingPositionReading { get }
    var fullText: any FullTextSearching { get }
    var covers: any CoverReading { get }
}

/// Read-write view of the library inside one transaction. Repositories also read, so code
/// that only needs reading can take the `…Reading` protocols and work in either kind.
public protocol WriteTransaction {
    var documents: any DocumentRepository { get }
    var pages: any PageRepository { get }
    var highlights: any HighlightRepository { get }
    var linkTargets: any LinkTargetRepository { get }
    var references: any ReferenceRepository { get }
    var trash: any TrashRepository { get }
    var settings: any SettingsRepository { get }
    var readingPositions: any ReadingPositionRepository { get }
    var fullText: any FullTextIndexing { get }
    var covers: any CoverRepository { get }
    var tombstones: any TombstoneRecording { get }
}

/// Errors any store may raise.
public enum StoreError: Error, Equatable, Sendable {
    case notFound(String)
    case conflict(String)
}

extension WriteTransaction {
    /// This transaction seen through the read-only protocols, for code written against
    /// `ReadTransaction`.
    public var reading: any ReadTransaction { ReadingView(base: self) }
}

private struct ReadingView: ReadTransaction {
    let base: any WriteTransaction
    var documents: any DocumentReading { base.documents }
    var pages: any PageReading { base.pages }
    var highlights: any HighlightReading { base.highlights }
    var linkTargets: any LinkTargetReading { base.linkTargets }
    var references: any ReferenceReading { base.references }
    var trash: any TrashReading { base.trash }
    var settings: any SettingsReading { base.settings }
    var readingPositions: any ReadingPositionReading { base.readingPositions }
    var fullText: any FullTextSearching { base.fullText }
    var covers: any CoverReading { base.covers }
}
