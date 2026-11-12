import Foundation
import GlossCore

/// Blobs in a dictionary, for tests and previews.
public final class InMemoryBlobStore: BlobStore, Sendable {
    private let blobs = Locked<[ContentHash: Data]>([:])

    public init() {}

    public func put(_ data: Data) async throws -> ContentHash {
        let hash = ContentHash.of(data)
        blobs.withLock { $0[hash] = data }
        return hash
    }

    public func data(for hash: ContentHash) async throws -> Data? { blobs.current[hash] }
    public func contains(_ hash: ContentHash) async throws -> Bool { blobs.current[hash] != nil }
    public func allHashes() async throws -> Set<ContentHash> { Set(blobs.current.keys) }
    public func delete(_ hash: ContentHash) async throws { blobs.withLock { $0[hash] = nil } }
}
