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

    /// Entries whose entities this window's trash actions restored or purged: AppModel tells
    /// the app's other windows (review 7; the journal's origin is per-process).
    public var onWrote: (@MainActor ([TrashEntry]) -> Void)?

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
        let restored = (try? await services.trash.restore(id)) ?? []
        lastRestored = restored
        await reload()
        return restored
    }

    public func purge(_ id: TrashEntryID) async {
        try? await services.trash.purge(id)
        lastRestored = []
        await reload()
    }

    public func empty() async {
        try? await services.trash.empty()
        lastRestored = []
        await reload()
    }

    public func setRetention(days: Int?) async {
        try? await services.settings.set(days, for: TrashSettings.retentionDays)
        await reload()
    }
}
