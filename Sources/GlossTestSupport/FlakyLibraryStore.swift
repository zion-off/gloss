import Foundation
import GlossCore

/// Wraps a store, counts its reads and fails them on demand: to test how callers treat a failed
/// lookup (it must never read as "gone") and how many round trips they make.
public final class FlakyLibraryStore: LibraryStore, @unchecked Sendable {
    public struct ReadFailure: Error {}

    private let base: any LibraryStore
    private let lock = NSLock()
    private var _failsReads = false
    private var _reads = 0

    public init(_ base: any LibraryStore) {
        self.base = base
    }

    public var failsReads: Bool {
        get { lock.withLock { _failsReads } }
        set { lock.withLock { _failsReads = newValue } }
    }

    /// Reads attempted so far.
    public var reads: Int { lock.withLock { _reads } }

    public func read<T: Sendable>(_ work: @escaping @Sendable (any ReadTransaction) throws -> T) async throws -> T {
        lock.withLock { _reads += 1 }
        if failsReads { throw ReadFailure() }
        return try await base.read(work)
    }

    public func write<T: Sendable>(_ work: @escaping @Sendable (any WriteTransaction) throws -> T) async throws -> T {
        try await base.write(work)
    }
}
