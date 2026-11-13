import Foundation

/// The trash window's contents (`TrashService.overview()`).
public struct TrashOverview: Hashable, Sendable {
    public struct Item: Hashable, Identifiable, Sendable {
        public var entry: TrashEntry
        /// When it will be purged, if retention is finite.
        public var expiresAt: Date?
        /// The book a trashed page belongs to (nil for books themselves).
        public var documentTitle: String?

        public var id: TrashEntryID { entry.id }
        public var title: String { entry.title }
    }

    /// Days items stay in the trash; nil keeps them forever.
    public var retentionDays: Int?
    public var items: [Item]
}

/// The trash: soft deletion with predictable restore and timed purging
/// (docs/ARCHITECTURE.md §3 "Trash").
public struct TrashService: Sendable {
    let store: any LibraryStore
    let ids: any IDGenerator
    let time: any TimeSource
    let handlers: [TrashableKind: any TrashableEntityHandler]

    public init(store: any LibraryStore, ids: any IDGenerator, time: any TimeSource, handlers: [any TrashableEntityHandler]) {
        self.store = store
        self.ids = ids
        self.time = time
        self.handlers = Dictionary(handlers.map { ($0.kind, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// The handlers gloss ships with.
    public static let standardHandlers: [any TrashableEntityHandler] = [DocumentTrashHandler(), PageTrashHandler()]

    public func entries() async throws -> [TrashEntry] {
        try await store.read { try $0.trash.trashEntries() }
    }

    /// What the trash window shows, in one read: every entry, newest first, with its expiry and,
    /// for pages, the title of their book.
    public func overview() async throws -> TrashOverview {
        try await store.read { tx in
            let days = try SettingsCodec().value(TrashSettings.retentionDays, in: tx.settings)
            var titles: [DocumentID: String?] = [:]
            let items = try tx.trash.trashEntries().map { entry -> TrashOverview.Item in
                var documentTitle: String?
                if entry.kind != .document, let id = entry.documentID {
                    if titles[id] == nil { titles[id] = .some(try tx.documents.document(id)?.title) }
                    documentTitle = titles[id] ?? nil
                }
                let expiry = days.map { entry.trashedAt.addingTimeInterval(TimeInterval($0) * 86_400) }
                return TrashOverview.Item(entry: entry, expiresAt: expiry, documentTitle: documentTitle)
            }
            return TrashOverview(retentionDays: days, items: items.sorted { $0.entry.trashedAt > $1.entry.trashedAt })
        }
    }

    /// When an entry will be purged, given the current retention setting.
    public func expiry(of entry: TrashEntry) async throws -> Date? {
        let days = try await store.read { try SettingsCodec().value(TrashSettings.retentionDays, in: $0.settings) }
        return days.map { entry.trashedAt.addingTimeInterval(TimeInterval($0) * 86_400) }
    }

    /// Moves an entity (and its cascade) to the trash.
    @discardableResult
    public func trash(_ kind: TrashableKind, id entityID: String) async throws -> TrashEntry {
        guard let handler = handlers[kind] else { throw GlossError.notAllowed("\(kind) can't go in the trash") }
        let now = time.now()
        let entryID: TrashEntryID = ids.make()
        return try await store.write { tx in
            let (title, documentID) = try handler.describe(entityID, in: tx)
            let entry = TrashEntry(id: entryID, kind: kind, entityID: entityID, documentID: documentID, title: title, trashedAt: now)
            try handler.stamp(entityID, with: TrashStamp(entryID: entryID, trashedAt: now), in: tx)
            try tx.trash.insert(entry)
            return entry
        }
    }

    /// Restores an entry's whole batch plus the batches of any trashed containers, so a page
    /// restored under a trashed parent brings its ancestors back. Returns every restored entry.
    @discardableResult
    public func restore(_ entryID: TrashEntryID) async throws -> [TrashEntry] {
        try await store.write { tx in
            guard try tx.trash.trashEntry(entryID) != nil else { throw GlossError.notFound("that item in the trash") }
            var pending = [entryID]
            var batches: [TrashEntryID] = []
            while let batch = pending.popLast() {
                guard !batches.contains(batch) else { continue }
                batches.append(batch)
                for handler in handlers.values {
                    pending += try handler.containerBatches(of: batch, in: tx).filter { !batches.contains($0) }
                }
            }
            var restored: [TrashEntry] = []
            for batch in batches {
                for handler in handlers.values { try handler.unstamp(batch: batch, in: tx) }
                if let entry = try tx.trash.trashEntry(batch) {
                    restored.append(entry)
                    try tx.trash.delete(batch)
                }
            }
            return restored
        }
    }

    /// Deletes an entry's batch for good.
    public func purge(_ entryID: TrashEntryID) async throws {
        let now = time.now()
        let ordered = handlers.values.sorted { $0.purgeOrder < $1.purgeOrder }
        try await store.write { tx in
            guard try tx.trash.trashEntry(entryID) != nil else { return }
            for handler in ordered { try handler.purge(batch: entryID, in: tx, now: now) }
            try tx.trash.delete(entryID)
        }
    }

    public func empty() async throws {
        for entry in try await entries() { try await purge(entry.id) }
    }

    /// Purges entries older than the retention setting. Returns how many.
    @discardableResult
    public func purgeExpired() async throws -> Int {
        let now = time.now()
        var purged = 0
        for entry in try await entries() {
            if let expiry = try await expiry(of: entry), expiry <= now {
                try await purge(entry.id)
                purged += 1
            }
        }
        return purged
    }
}
