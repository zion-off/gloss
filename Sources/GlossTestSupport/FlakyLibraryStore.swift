import Foundation
import GlossCore

/// Wraps a store and fails its reads on demand, to test how callers treat a failed lookup
/// (it must never read as "gone").
public final class FlakyLibraryStore: LibraryStore, @unchecked Sendable {
    public struct ReadFailure: Error {}

    private let base: any LibraryStore
    private let lock = NSLock()
    private var _failsReads = false

    public init(_ base: any LibraryStore) {
        self.base = base
    }

    public var failsReads: Bool {
        get { lock.withLock { _failsReads } }
        set { lock.withLock { _failsReads = newValue } }
    }

    public func read<T: Sendable>(_ work: @escaping @Sendable (any ReadTransaction) throws -> T) async throws -> T {
        if failsReads { throw ReadFailure() }
        return try await base.read(work)
    }

    public func write<T: Sendable>(_ work: @escaping @Sendable (any WriteTransaction) throws -> T) async throws -> T {
        try await base.write(work)
    }
}
