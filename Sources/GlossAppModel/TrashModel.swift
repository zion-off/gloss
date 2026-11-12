import Foundation
import Observation
import GlossCore

/// The trash window: entries, what's inside them, restore and purge.
@MainActor @Observable public final class TrashModel {
    public struct Item: Hashable, Identifiable, Sendable {
        public var entry: TrashEntry
        /// When it will be purged, if retention is finite.
        public var expiresAt: Date?

        /// The book a trashed page belongs to (nil for books themselves).
        public var documentTitle: String?

        public var id: TrashEntryID { entry.id }
        public var title: String { entry.title }
    }

    public private(set) var items: [Item] = []
    public private(set) var retentionDays: Int? = 30

    private let services: GlossServices

    public init(services: GlossServices) {
        self.services = services
    }

    public func reload() async {
        let entries = (try? await services.trash.entries()) ?? []
        retentionDays = (try? await services.settings.value(TrashSettings.retentionDays)) ?? nil
        var titles: [DocumentID: String] = [:]
        var loaded: [Item] = []
        for entry in entries {
            var documentTitle: String?
            if entry.kind != .document, let id = entry.documentID {
                if titles[id] == nil { titles[id] = try? await services.library.document(id)?.title }
                documentTitle = titles[id]
            }
            let expiry = (try? await services.trash.expiry(of: entry)) ?? nil
            loaded.append(Item(entry: entry, expiresAt: expiry, documentTitle: documentTitle))
        }
        items = loaded.sorted { $0.entry.trashedAt > $1.entry.trashedAt }
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
