import Foundation
import GlossMarkdown

/// Garbage-collects unreferenced link targets and degrades links whose destination is gone.
public struct LinkMaintenance: Sendable {
    /// How long an unreferenced target survives (undo, cut-and-paste, trash restores).
    public static let orphanGracePeriod: TimeInterval = 7 * 24 * 60 * 60

    let store: any LibraryStore
    let time: any TimeSource

    public init(store: any LibraryStore, time: any TimeSource) {
        self.store = store
        self.time = time
    }

    /// Deletes targets orphaned for longer than the grace period. Returns how many.
    @discardableResult
    public func sweepOrphanedTargets(gracePeriod: TimeInterval = LinkMaintenance.orphanGracePeriod) async throws -> Int {
        let now = time.now()
        return try await store.write { tx in
            var removed = 0
            for target in try tx.linkTargets.orphanedLinkTargets(since: now.addingTimeInterval(-gracePeriod)) {
                // Re-check: a reference may exist if orphan marks drifted.
                if try tx.references.referringPages(to: .passage(target.id)).isEmpty {
                    try LinkMaintenance.deleteTarget(target.id, in: tx, now: now)
                    removed += 1
                } else {
                    var fixed = target
                    fixed.orphanedSince = nil
                    try tx.linkTargets.update(fixed)
                }
            }
            return removed
        }
    }

    /// Removes a target, degrading every link to it into plain text first.
    public func removeTarget(_ id: LinkTargetID) async throws {
        let now = time.now()
        try await store.write { tx in
            try LinkMaintenance.degradeReferences(to: .passage(id), in: tx, now: now)
            try LinkMaintenance.deleteTarget(id, in: tx, now: now)
        }
    }

    // MARK: Transaction-level operations (used by trash purges)

    static func deleteTarget(_ id: LinkTargetID, in tx: any WriteTransaction, now: Date) throws {
        try tx.linkTargets.delete(id)
        try tx.tombstones.recordDeletion(entity: ChangeEntity.linkTarget, id: id.stringValue, at: now)
    }

    /// Rewrites every page linking to `target`, replacing `[label](gloss://…)` with `label`.
    /// The line of text survives; only the link goes.
    static func degradeReferences(to target: ReferenceTarget, in tx: any WriteTransaction, now: Date,
                                  skipping skipped: Set<PageID> = []) throws {
        for pageID in try tx.references.referringPages(to: target) where !skipped.contains(pageID) {
            guard var page = try tx.pages.page(pageID) else { continue }
            let body = LinkScanner.rewrite(page.body) { link in
                GlossLink(string: link.destination)?.referenceTarget == target ? link.label : nil
            }
            guard body != page.body else { continue }
            page.body = body
            page.updatedAt = now
            try tx.pages.update(page)
            try NotesIndexer.index(page, in: tx)
            try ReferenceTracker.update(page, in: tx, now: now)
        }
    }
}
