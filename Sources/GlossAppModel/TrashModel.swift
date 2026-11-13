import Foundation
import Observation
import GlossCore

/// The trash window: entries, what's inside them, restore and purge.
@MainActor @Observable public final class TrashModel {
    public typealias Item = TrashOverview.Item

    public private(set) var items: [Item] = []
    public private(set) var retentionDays: Int? = 30
    /// What the last restore brought back, so the view can say so ("restored “x” and 2 more").
    public private(set) var lastRestored: [TrashEntry] = []
    /// Why the last restore brought nothing back; nil when it worked (review 7). Purging the
    /// entry or emptying the trash clears it: the situation it described is over (review 8).
    public private(set) var restoreProblem: String?

    /// Entries whose entities this window's trash actions restored or purged: AppModel tells
    /// the app's other windows (review 7; the journal's origin is per-process).
    public var onWrote: (@MainActor ([TrashEntry]) -> Void)?
    /// This window changed how long the trash keeps things: AppModel tells the app's other
    /// windows, whose expiry lines re-date themselves (review 8; same per-process origin gap).
    public var onRetentionChanged: (@MainActor () -> Void)?

    private let services: GlossServices

    public init(services: GlossServices) {
        self.services = services
    }

    /// What the view says after the last restore, once it has been shown (nil before).
    public var lastRestoredMessage: String? {
        guard let first = lastRestored.first else { return nil }
        let extras = lastRestored.count - 1
        return extras == 0 ? "restored “\(first.title)”" : "restored “\(first.title)” and \(extras) more"
    }

    /// Reloads the list in one read (a long trash must not stall the main actor). A failed
    /// read keeps what is shown.
    public func reload() async {
        guard let overview = try? await services.trash.overview() else { return }
        retentionDays = overview.retentionDays
        items = overview.items
    }

    @discardableResult
    public func restore(_ id: TrashEntryID) async -> [TrashEntry] {
        do {
            let restored = try await services.trash.restore(id)
            lastRestored = restored
            restoreProblem = nil
            onWrote?(restored)
            await reload()
            return restored
        } catch {
            // Nothing came back (purged from the cli meanwhile, or a failed read): the view
            // says so instead of staying silent (review 7).
            lastRestored = []
            restoreProblem = "couldn't put it back — it may have gone for good"
            await reload()
            return []
        }
    }

    public func purge(_ id: TrashEntryID) async {
        try? await services.trash.purge(id)
        lastRestored = []
        // The entry it described is gone, so the problem line goes with it (review 8).
        restoreProblem = nil
        onWrote?(items.first { $0.id == id }.map { [$0.entry] } ?? [])
        await reload()
    }

    public func empty() async {
        try? await services.trash.empty()
        lastRestored = []
        restoreProblem = nil  // ditto: everything the line could be about is gone
        onWrote?(items.map(\.entry))
        await reload()
    }

    public func setRetention(days: Int?) async {
        try? await services.settings.set(days, for: TrashSettings.retentionDays)
        onRetentionChanged?()
        await reload()
    }
}
