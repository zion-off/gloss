import Foundation

/// Teaches the trash about one kind of deletable entity. Register a handler to make a new
/// entity deletable; `TrashService` never branches on kinds.
public protocol TrashableEntityHandler: Sendable {
    var kind: TrashableKind { get }
    /// Lower purges first (children before their containers).
    var purgeOrder: Int { get }

    /// Title and owning document of a live entity, for the trash entry.
    func describe(_ entityID: String, in tx: any WriteTransaction) throws -> (title: String, documentID: DocumentID?)
    /// Stamps the entity and everything that cascades with it. Throws if it cannot be trashed.
    func stamp(_ entityID: String, with stamp: TrashStamp, in tx: any WriteTransaction) throws
    /// Clears the stamps this kind holds for a batch.
    func unstamp(batch: TrashEntryID, in tx: any WriteTransaction) throws
    /// Other batches holding containers of this kind's rows in `batch` (a trashed parent page,
    /// a trashed document). Restoring the batch restores those too.
    func containerBatches(of batch: TrashEntryID, in tx: any WriteTransaction) throws -> Set<TrashEntryID>
    /// Hard-deletes this kind's rows in a batch.
    func purge(batch: TrashEntryID, in tx: any WriteTransaction, now: Date) throws
}

public enum TrashSettings {
    /// Days items stay in the trash; `nil` keeps them forever.
    public static let retentionDays = SettingKey<Int?>("trash.retentionDays", default: 30)
}
