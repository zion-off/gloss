import Foundation

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
