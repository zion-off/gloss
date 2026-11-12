import Foundation

/// Documents: trashing stamps the document and its live pages; purging removes everything the
/// document owns and degrades links into it from other books.
public struct DocumentTrashHandler: TrashableEntityHandler {
    public init() {}
    public var kind: TrashableKind { .document }
    public var purgeOrder: Int { 20 }

    private func id(_ raw: String) throws -> DocumentID {
        guard let id = DocumentID(raw) else { throw GlossError.invalid("not a book id: \(raw)") }
        return id
    }

    public func describe(_ entityID: String, in tx: any WriteTransaction) throws -> (title: String, documentID: DocumentID?) {
        guard let document = try tx.documents.document(try id(entityID)) else { throw GlossError.notFound("that book") }
        guard document.trash == nil else { throw GlossError.inTrash(document.title) }
        return (document.title, document.id)
    }

    public func stamp(_ entityID: String, with stamp: TrashStamp, in tx: any WriteTransaction) throws {
        guard var document = try tx.documents.document(try id(entityID)) else { throw GlossError.notFound("that book") }
        document.trash = stamp
        try tx.documents.update(document)
        for var page in try tx.pages.pages(in: document.id, .live) {
            page.trash = stamp
            try tx.pages.update(page)
        }
    }

    public func unstamp(batch: TrashEntryID, in tx: any WriteTransaction) throws {
        for var document in try tx.documents.documents(inTrashEntry: batch) {
            document.trash = nil
            try tx.documents.update(document)
        }
    }

    public func containerBatches(of batch: TrashEntryID, in tx: any WriteTransaction) throws -> Set<TrashEntryID> { [] }

    public func purge(batch: TrashEntryID, in tx: any WriteTransaction, now: Date) throws {
        for document in try tx.documents.documents(inTrashEntry: batch) {
            let pages = try tx.pages.pages(in: document.id, .any)
            let ownPages = Set(pages.map(\.id))
            // Links from other books into this one become plain text.
            for target in try tx.linkTargets.linkTargets(in: document.id) {
                try LinkMaintenance.degradeReferences(to: .passage(target.id), in: tx, now: now, skipping: ownPages)
                try LinkMaintenance.deleteTarget(target.id, in: tx, now: now)
            }
            for page in pages {
                try LinkMaintenance.degradeReferences(to: .page(page.id), in: tx, now: now, skipping: ownPages)
            }
            try LinkMaintenance.degradeReferences(to: .document(document.id), in: tx, now: now, skipping: ownPages)
            // Pages trashed earlier on their own go with the book, entries included.
            for entry in try tx.trash.trashEntries() where entry.documentID == document.id && entry.id != batch {
                try tx.trash.delete(entry.id)
            }
            for page in pages.sorted(by: { depth($0, in: pages) > depth($1, in: pages) }) {
                try PageTrashHandler.purgeRow(page, in: tx, now: now)
            }
            for highlight in try tx.highlights.highlights(in: document.id) {
                try tx.highlights.delete(highlight.id)
                try tx.tombstones.recordDeletion(entity: ChangeEntity.highlight, id: highlight.id.stringValue, at: now)
            }
            try tx.readingPositions.deleteReadingPosition(of: document.id)
            try tx.covers.setDerivedCover(nil, of: document.id)
            try BookTextIndexer.remove(document.id, in: tx)
            try LibraryIndexer.remove(document.id, in: tx)
            try tx.documents.delete(document.id)
            try tx.tombstones.recordDeletion(entity: ChangeEntity.document, id: document.id.stringValue, at: now)
        }
    }

    private func depth(_ page: Page, in pages: [Page]) -> Int {
        let byID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        var depth = 0
        var cursor = page.parentID
        while let id = cursor, let parent = byID[id], depth < pages.count {
            depth += 1
            cursor = parent.parentID
        }
        return depth
    }
}

/// Pages: trashing stamps the page and its live subtree (never the root page); restoring pulls
/// in trashed ancestors and a trashed document; purging removes the subtree.
public struct PageTrashHandler: TrashableEntityHandler {
    public init() {}
    public var kind: TrashableKind { .page }
    public var purgeOrder: Int { 10 }

    private func id(_ raw: String) throws -> PageID {
        guard let id = PageID(raw) else { throw GlossError.invalid("not a page id: \(raw)") }
        return id
    }

    public func describe(_ entityID: String, in tx: any WriteTransaction) throws -> (title: String, documentID: DocumentID?) {
        guard let page = try tx.pages.page(try id(entityID)) else { throw GlossError.notFound("that page") }
        guard page.parentID != nil else {
            throw GlossError.notAllowed("a book's main notes page can't be trashed on its own — trash the book instead")
        }
        guard page.trash == nil else { throw GlossError.inTrash(page.title) }
        return (page.title.isEmpty ? PageService.untitled : page.title, page.documentID)
    }

    public func stamp(_ entityID: String, with stamp: TrashStamp, in tx: any WriteTransaction) throws {
        guard var page = try tx.pages.page(try id(entityID)) else { throw GlossError.notFound("that page") }
        page.trash = stamp
        try tx.pages.update(page)
        for var descendant in try PageService.descendants(of: page.id, in: tx.pages) where descendant.trash == nil {
            descendant.trash = stamp
            try tx.pages.update(descendant)
        }
    }

    public func unstamp(batch: TrashEntryID, in tx: any WriteTransaction) throws {
        for var page in try tx.pages.pages(inTrashEntry: batch) {
            page.trash = nil
            try tx.pages.update(page)
        }
    }

    public func containerBatches(of batch: TrashEntryID, in tx: any WriteTransaction) throws -> Set<TrashEntryID> {
        var result: Set<TrashEntryID> = []
        for page in try tx.pages.pages(inTrashEntry: batch) {
            if let stamp = try tx.documents.document(page.documentID)?.trash, stamp.entryID != batch { result.insert(stamp.entryID) }
            var cursor = page.parentID
            while let parentID = cursor, let parent = try tx.pages.page(parentID) {
                if let stamp = parent.trash, stamp.entryID != batch { result.insert(stamp.entryID) }
                cursor = parent.parentID
            }
        }
        return result
    }

    public func purge(batch: TrashEntryID, in tx: any WriteTransaction, now: Date) throws {
        let pages = try tx.pages.pages(inTrashEntry: batch)
        guard !pages.isEmpty else { return }
        let ids = Set(pages.map(\.id))
        // Descendants trashed earlier in their own batches go too: nothing may point at a
        // purged parent.
        var doomed = pages
        for page in pages {
            for descendant in try PageService.descendants(of: page.id, in: tx.pages) where !ids.contains(descendant.id) {
                doomed.append(descendant)
                if let stamp = descendant.trash, stamp.entryID != batch { try tx.trash.delete(stamp.entryID) }
            }
        }
        let doomedIDs = Set(doomed.map(\.id))
        for page in doomed {
            try LinkMaintenance.degradeReferences(to: .page(page.id), in: tx, now: now, skipping: doomedIDs)
        }
        // Children before parents.
        var remaining = doomed
        while !remaining.isEmpty {
            let parentIDs = Set(remaining.compactMap(\.parentID))
            let leaves = remaining.filter { !parentIDs.contains($0.id) }
            for leaf in leaves { try PageTrashHandler.purgeRow(leaf, in: tx, now: now) }
            remaining.removeAll { leaf in leaves.contains { $0.id == leaf.id } }
            if leaves.isEmpty { break }
        }
    }

    static func purgeRow(_ page: Page, in tx: any WriteTransaction, now: Date) throws {
        try ReferenceTracker.clear(page.id, in: tx, now: now)
        try NotesIndexer.remove(page.id, in: tx)
        try tx.pages.delete(page.id)
        try tx.tombstones.recordDeletion(entity: ChangeEntity.page, id: page.id.stringValue, at: now)
    }
}
