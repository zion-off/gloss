import Foundation
import GlossCore
import GlossMemoryStore

/// A clock tests can move by hand.
public final class ManualTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    public init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.date = date
    }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(interval)
    }

    public func set(_ newDate: Date) {
        lock.lock(); defer { lock.unlock() }
        date = newDate
    }
}

/// Deterministic, strictly increasing IDs.
public final class SequentialIDGenerator: IDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64

    public init(start: UInt64 = 1) { counter = start }

    public func next() -> GlossID {
        lock.lock(); defer { lock.unlock() }
        defer { counter += 1 }
        return GlossID(high: 0x0000_0000_0000_7000, low: counter)
    }
}

public extension Date {
    static let testEpoch = Date(timeIntervalSince1970: 1_800_000_000)
}
