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

    /// Rows fetched per query.
    static let pageSize = 500

    /// Returns changes since the last poll, ignoring this process's own writes. Reads in pages
    /// until the journal is drained, and only advances past rows it actually received, so a big
    /// import from the CLI or a write landing mid-poll is never skipped.
    @discardableResult
    public func poll() async -> [ChangeRecord] {
        var changes: [ChangeRecord] = []
        while let batch = try? await feed.changes(after: lastSequence, limit: Self.pageSize), !batch.isEmpty {
            changes += batch
            lastSequence = batch.last?.sequence ?? lastSequence
            if batch.count < Self.pageSize { break }
        }
        lastPolledAt = Date()
        let foreign = changes.filter { $0.origin != feed.origin }
        if !foreign.isEmpty {
            pendingChanges = foreign
            await onChanges(foreign)
        }
        return foreign
    }
}
