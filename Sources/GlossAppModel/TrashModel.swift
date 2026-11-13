import Foundation
import Observation
import GlossCore

/// The trash window: entries, what's inside them, restore and purge.
@MainActor @Observable public final class TrashModel {
    public typealias Item = TrashOverview.Item

    public private(set) var items: [Item] = []
    public private(set) var retentionDays: Int? = 30

    private let services: GlossServices

    public init(services: GlossServices) {
        self.services = services
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
        await reload()
        return restored
    }

    public func purge(_ id: TrashEntryID) async {
        try? await services.trash.purge(id)
        await reload()
    }

    public func empty() async {
        try? await services.trash.empty()
        await reload()
    }

    public func setRetention(days: Int?) async {
        try? await services.settings.set(days, for: TrashSettings.retentionDays)
        await reload()
    }
}
