import Foundation
import Observation
import GlossCore

/// The trash window: entries, what's inside them, restore and purge.
@MainActor @Observable public final class TrashModel {
    public struct Item: Hashable, Identifiable, Sendable {
        public var entry: TrashEntry
        /// When it will be purged, if retention is finite.
        public var expiresAt: Date?

        public var id: TrashEntryID { entry.id }
        public var title: String { entry.title }
        public var documentTitle: String? { entry.kind == .document ? nil : nil }
    }

    public private(set) var items: [Item] = []
    public private(set) var retentionDays: Int? = 30

    private let services: GlossServices

    public init(services: GlossServices) {
        self.services = services
    }

    public func reload() async {
        let entries = (try? await services.trash.entries()) ?? []
        let retention = try? await services.settings.value(TrashSettings.retentionDays)
        retentionDays = retention ?? nil
        items = await withTaskGroup(of: (TrashEntry, Date?).self) { group in
            for entry in entries {
                group.addTask { [services] in
                    let expiry = try? await services.trash.expiry(of: entry)
                    return (entry, expiry ?? nil)
                }
            }
            var result: [(TrashEntry, Date?)] = []
            for await pair in group { result.append(pair) }
            return result.sorted { $0.0.trashedAt > $1.0.trashedAt }
        }.map { Item(entry: $0.0, expiresAt: $0.1) }
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
