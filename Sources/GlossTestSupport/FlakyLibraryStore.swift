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
    private var _parkNextRead = false
    private var parked: CheckedContinuation<Void, Never>?
    private var _parkedReads = 0

    public init(_ base: any LibraryStore) {
        self.base = base
    }

    public var failsReads: Bool {
        get { lock.withLock { _failsReads } }
        set { lock.withLock { _failsReads = newValue } }
    }

    /// Reads attempted so far.
    public var reads: Int { lock.withLock { _reads } }

    /// Parks the next read until `releaseParkedRead()` (race tests: a stale query landing after
    /// a newer one). The parked read's continuation is stored under the same lock.
    public var parkNextRead: Bool {
        get { lock.withLock { _parkNextRead } }
        set { lock.withLock { _parkNextRead = newValue } }
    }

    /// Reads parked so far (a test waits for this before releasing).
    public var parkedReads: Int { lock.withLock { _parkedReads } }

    /// Lets a parked read continue.
    public func releaseParkedRead() {
        let continuation = lock.withLock {
            defer { parked = nil }
            return parked
        }
        continuation?.resume()
    }

    public func read<T: Sendable>(_ work: @escaping @Sendable (any ReadTransaction) throws -> T) async throws -> T {
        lock.withLock { _reads += 1 }
        if failsReads { throw ReadFailure() }
        if lock.withLock({ _parkNextRead }) {
            lock.withLock {
                _parkNextRead = false
                _parkedReads += 1
            }
            await withCheckedContinuation { continuation in
                lock.withLock { parked = continuation }
            }
        }
        return try await base.read(work)
    }

    public func write<T: Sendable>(_ work: @escaping @Sendable (any WriteTransaction) throws -> T) async throws -> T {
        try await base.write(work)
    }
}
