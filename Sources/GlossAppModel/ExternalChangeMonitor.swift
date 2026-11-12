import Foundation
import Observation
import GlossCore

/// Notices writes made by other processes (the CLI, another window) by polling the change
/// journal. The Mac layer calls `poll()` on a timer; tests call it by hand.
@MainActor @Observable public final class ExternalChangeMonitor {
    public private(set) var lastPolledAt: Date?
    public private(set) var pendingChanges: [ChangeRecord] = []

    private let feed: any ChangeFeed
    private var lastSequence: Int64
    private let onChanges: @MainActor @Sendable ([ChangeRecord]) async -> Void

    public init(feed: any ChangeFeed, onChanges: @MainActor @escaping @Sendable ([ChangeRecord]) async -> Void) async {
        self.feed = feed
        self.onChanges = onChanges
        self.lastSequence = (try? await feed.latestChangeSequence()) ?? 0
    }

    /// Returns changes since the last poll, ignoring this process's own writes.
    @discardableResult
    public func poll() async -> [ChangeRecord] {
        guard let changes = try? await feed.changes(after: lastSequence, limit: 500) else { return [] }
        lastSequence = (try? await feed.latestChangeSequence()) ?? lastSequence
        lastPolledAt = Date()
        let foreign = changes.filter { $0.origin != feed.origin }
        if !foreign.isEmpty {
            pendingChanges = foreign
            await onChanges(foreign)
        }
        return foreign
    }
}
