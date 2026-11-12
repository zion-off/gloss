import Foundation

/// Where the core gets "now" from. Injected everywhere so tests control time.
public protocol TimeSource: Sendable {
    func now() -> Date
}

/// The real clock.
public struct SystemTimeSource: TimeSource {
    public init() {}
    public func now() -> Date { Date() }
}
