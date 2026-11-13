import Foundation
import GlossCore

/// Wraps a store, counts its reads and fails them on demand: to test how callers treat a failed
/// lookup (it must never read as "gone") and how many round trips they make.
public final class FlakyLibraryStore: LibraryStore, @unchecked Sendable {
    public struct ReadFailure: Error {}

    private let base: any LibraryStore
    private let lock = NSLock()
    private var _failsReads = false
    private var _failsWrites = false
    private var _reads = 0
    private var _parkNextRead = false
    /// Parked reads, oldest first (review 8: a single slot made a second parked read overwrite
    /// the first continuation, and a release landing before the park was silently dropped).
    private var parkedQueue: [CheckedContinuation<Void, Never>] = []
    /// Releases that arrived while nothing was parked; the next park consumes one instead.
    private var _pendingReleases = 0
    private var _parkedReads = 0

    public init(_ base: any LibraryStore) {
        self.base = base
    }

    public var failsReads: Bool {
        get { lock.withLock { _failsReads } }
        set { lock.withLock { _failsReads = newValue } }
    }

    /// Writes fail on demand too (a save that must not be announced, review 7).
    public var failsWrites: Bool {
        get { lock.withLock { _failsWrites } }
        set { lock.withLock { _failsWrites = newValue } }
    }

    /// Reads attempted so far.
    public var reads: Int { lock.withLock { _reads } }

    /// Parks the next read until `releaseParkedRead()` (race tests: a stale query landing after
    /// a newer one). Further parked reads queue up; releases are spent oldest-first.
    public var parkNextRead: Bool {
        get { lock.withLock { _parkNextRead } }
        set { lock.withLock { _parkNextRead = newValue } }
    }

    /// Reads parked so far (a test waits for this before releasing).
    public var parkedReads: Int { lock.withLock { _parkedReads } }

    /// Lets a parked read continue. With none parked, the next park runs straight through, so a
    /// release can never be lost to a race with the park itself (review 8).
    public func releaseParkedRead() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            if parkedQueue.isEmpty {
                _pendingReleases += 1
                return nil
            }
            return parkedQueue.removeFirst()
        }
        continuation?.resume()
    }

    public func read<T: Sendable>(_ work: @escaping @Sendable (any ReadTransaction) throws -> T) async throws -> T {
        lock.withLock { _reads += 1 }
        if failsReads { throw ReadFailure() }
        if lock.withLock({ _parkNextRead }) {
            let shouldPark: Bool = lock.withLock {
                _parkNextRead = false
                if _pendingReleases > 0 {
                    _pendingReleases -= 1
                    return false  // a release was already waiting: run straight through
                }
                _parkedReads += 1
                return true
            }
            if shouldPark {
                await withCheckedContinuation { continuation in
                    let resumeNow = lock.withLock {
                        if _pendingReleases > 0 {  // a release raced the queueing: use it
                            _pendingReleases -= 1
                            return true
                        }
                        parkedQueue.append(continuation)
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            }
        }
        return try await base.read(work)
    }

    public func write<T: Sendable>(_ work: @escaping @Sendable (any WriteTransaction) throws -> T) async throws -> T {
        if failsWrites { throw ReadFailure() }
        return try await base.write(work)
    }
}
