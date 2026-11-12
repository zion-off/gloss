import Foundation

/// Keeps `PageReference`s and link-target orphan marks in step with page bodies
/// (docs/ARCHITECTURE.md §3, docs/DECISIONS.md D-023/D-024).
public enum ReferenceTracker {
    /// Re-derives the references of `page` from its body.
    public static func update(_ page: Page, in tx: any WriteTransaction, now: Date) throws {
        try setReferences(ReferenceExtractor.references(in: page.body), from: page.id, in: tx, now: now)
    }

    /// Drops every reference a page makes (used when it is purged).
    public static func clear(_ pageID: PageID, in tx: any WriteTransaction, now: Date) throws {
        try setReferences([], from: pageID, in: tx, now: now)
    }

    static func setReferences(_ new: Set<ReferenceTarget>, from pageID: PageID, in tx: any WriteTransaction, now: Date) throws {
        let old = try tx.references.references(from: pageID)
        guard old != new else { return }
        try tx.references.setReferences(new, from: pageID)
        for case .passage(let id) in old.subtracting(new) {
            guard var target = try tx.linkTargets.linkTarget(id), target.orphanedSince == nil else { continue }
            if try tx.references.referringPages(to: .passage(id)).isEmpty {
                target.orphanedSince = now
                try tx.linkTargets.update(target)
            }
        }
        for case .passage(let id) in new.subtracting(old) {
            guard var target = try tx.linkTargets.linkTarget(id), target.orphanedSince != nil else { continue }
            target.orphanedSince = nil
            try tx.linkTargets.update(target)
        }
    }
}
