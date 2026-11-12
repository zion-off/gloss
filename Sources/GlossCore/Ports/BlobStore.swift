import Foundation

/// Immutable, content-addressed file storage, kept apart from the small rows so it can move
/// out of SQLite later (e.g. to files or iCloud assets) without touching the core.
public protocol BlobStore: Sendable {
    /// Stores `data` and returns its hash. Idempotent.
    @discardableResult
    func put(_ data: Data) async throws -> ContentHash
    func data(for hash: ContentHash) async throws -> Data?
    func contains(_ hash: ContentHash) async throws -> Bool
    func allHashes() async throws -> Set<ContentHash>
    func delete(_ hash: ContentHash) async throws
}
