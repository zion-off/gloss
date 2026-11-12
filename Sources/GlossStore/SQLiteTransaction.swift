import Foundation
import GlossCore
import GRDB

/// One GRDB transaction playing every repository role. Writes are journaled in `changes` with
/// the store's origin so other processes can notice them.
final class SQLiteTransaction: WriteTransaction {
    let db: Database
    let origin: String
    let now: Date

    init(db: Database, origin: String, now: Date) {
        self.db = db
        self.origin = origin
        self.now = now
    }

    func journal(_ entity: String, _ id: CustomStringConvertible) throws {
        try db.execute(sql: "INSERT INTO changes (entity, entity_id, origin, at) VALUES (?, ?, ?, ?)",
                       arguments: [entity, id.description, origin, Columns.date(now)])
    }

    var documents: any DocumentRepository { self }
    var pages: any PageRepository { self }
    var highlights: any HighlightRepository { self }
    var linkTargets: any LinkTargetRepository { self }
    var references: any ReferenceRepository { self }
    var trash: any TrashRepository { self }
    var settings: any SettingsRepository { self }
    var readingPositions: any ReadingPositionRepository { self }
    var fullText: any FullTextIndexing { self }
    var covers: any CoverRepository { self }
    var tombstones: any TombstoneRecording { self }

    private func requireChange(_ what: String) throws {
        if db.changesCount == 0 { throw StoreError.notFound(what) }
    }
}

// MARK: Documents

extension SQLiteTransaction: DocumentRepository {
    func document(_ id: DocumentID) throws -> Document? {
        try Row.fetchOne(db, sql: "SELECT * FROM documents WHERE id = ?", arguments: [id.stringValue]).map(Document.init(row:))
    }

    func documents(_ filter: TrashFilter) throws -> [Document] {
        let condition = switch filter {
        case .live: "WHERE trash_entry IS NULL"
        case .trashed: "WHERE trash_entry IS NOT NULL"
        case .any: ""
        }
        return try Row.fetchAll(db, sql: "SELECT * FROM documents \(condition) ORDER BY id").map(Document.init(row:))
    }

    func documents(withContentHash hash: ContentHash) throws -> [Document] {
        try Row.fetchAll(db, sql: "SELECT * FROM documents WHERE content_hash = ? ORDER BY id", arguments: [hash.hex]).map(Document.init(row:))
    }

    func documents(inTrashEntry entryID: TrashEntryID) throws -> [Document] {
        try Row.fetchAll(db, sql: "SELECT * FROM documents WHERE trash_entry = ? ORDER BY id", arguments: [entryID.stringValue]).map(Document.init(row:))
    }

    func referencedBlobHashes() throws -> Set<ContentHash> {
        let hashes = try String.fetchAll(db, sql: "SELECT content_hash FROM documents UNION SELECT cover_hash FROM documents WHERE cover_hash IS NOT NULL")
        return Set(hashes.compactMap(ContentHash.init(hex:)))
    }

    func insert(_ document: Document) throws {
        do {
            try db.execute(sql: """
                INSERT INTO documents (id, kind, title, author, content_hash, file_size, original_filename, cover_hash, metadata,
                    added_at, updated_at, last_opened_at, trash_entry, trashed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: document.arguments)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            throw StoreError.conflict("document \(document.id)")
        }
        try journal(ChangeEntity.document, document.id)
    }

    func update(_ document: Document) throws {
        var arguments = document.arguments
        _ = arguments.append(contentsOf: [document.id.stringValue])
        try db.execute(sql: """
            UPDATE documents SET id = ?, kind = ?, title = ?, author = ?, content_hash = ?, file_size = ?, original_filename = ?,
                cover_hash = ?, metadata = ?, added_at = ?, updated_at = ?, last_opened_at = ?, trash_entry = ?, trashed_at = ?
            WHERE id = ?
            """, arguments: arguments)
        try requireChange("document \(document.id)")
        try journal(ChangeEntity.document, document.id)
    }

    func delete(_ id: DocumentID) throws {
        try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [id.stringValue])
        try journal(ChangeEntity.document, id)
    }
}

// MARK: Pages

extension SQLiteTransaction: PageRepository {
    private static let pageOrder = "ORDER BY position, id"

    private func trashCondition(_ filter: TrashFilter) -> String {
        switch filter {
        case .live: "AND trash_entry IS NULL"
        case .trashed: "AND trash_entry IS NOT NULL"
        case .any: ""
        }
    }

    func page(_ id: PageID) throws -> Page? {
        try Row.fetchOne(db, sql: "SELECT * FROM pages WHERE id = ?", arguments: [id.stringValue]).map(Page.init(row:))
    }

    func rootPage(of documentID: DocumentID) throws -> Page? {
        try Row.fetchOne(db, sql: "SELECT * FROM pages WHERE document_id = ? AND parent_id IS NULL", arguments: [documentID.stringValue]).map(Page.init(row:))
    }

    func pages(in documentID: DocumentID, _ filter: TrashFilter) throws -> [Page] {
        try Row.fetchAll(db, sql: "SELECT * FROM pages WHERE document_id = ? \(trashCondition(filter)) \(Self.pageOrder)",
                         arguments: [documentID.stringValue]).map(Page.init(row:))
    }

    func children(of pageID: PageID, _ filter: TrashFilter) throws -> [Page] {
        try Row.fetchAll(db, sql: "SELECT * FROM pages WHERE parent_id = ? \(trashCondition(filter)) \(Self.pageOrder)",
                         arguments: [pageID.stringValue]).map(Page.init(row:))
    }

    func pages(_ filter: TrashFilter) throws -> [Page] {
        try Row.fetchAll(db, sql: "SELECT * FROM pages WHERE 1 \(trashCondition(filter)) \(Self.pageOrder)").map(Page.init(row:))
    }

    func pages(inTrashEntry entryID: TrashEntryID) throws -> [Page] {
        try Row.fetchAll(db, sql: "SELECT * FROM pages WHERE trash_entry = ? \(Self.pageOrder)", arguments: [entryID.stringValue]).map(Page.init(row:))
    }

    func insert(_ page: Page) throws {
        do {
            try db.execute(sql: """
                INSERT INTO pages (id, document_id, parent_id, title, body, position, created_at, updated_at, trash_entry, trashed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: page.arguments)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            throw StoreError.conflict("page \(page.id)")
        }
        try journal(ChangeEntity.page, page.id)
    }

    func update(_ page: Page) throws {
        var arguments = page.arguments
        _ = arguments.append(contentsOf: [page.id.stringValue])
        try db.execute(sql: """
            UPDATE pages SET id = ?, document_id = ?, parent_id = ?, title = ?, body = ?, position = ?, created_at = ?, updated_at = ?,
                trash_entry = ?, trashed_at = ?
            WHERE id = ?
            """, arguments: arguments)
        try requireChange("page \(page.id)")
        try journal(ChangeEntity.page, page.id)
    }

    func delete(_ id: PageID) throws {
        try db.execute(sql: "DELETE FROM pages WHERE id = ?", arguments: [id.stringValue])
        try journal(ChangeEntity.page, id)
    }
}

// MARK: Highlights and link targets

extension SQLiteTransaction: HighlightRepository {
    func highlight(_ id: HighlightID) throws -> Highlight? {
        try Row.fetchOne(db, sql: "SELECT * FROM highlights WHERE id = ?", arguments: [id.stringValue]).map(Highlight.init(row:))
    }

    func highlights(in documentID: DocumentID) throws -> [Highlight] {
        try Row.fetchAll(db, sql: "SELECT * FROM highlights WHERE document_id = ? ORDER BY IFNULL(progression, 0), created_at, id",
                         arguments: [documentID.stringValue]).map(Highlight.init(row:))
    }

    func insert(_ highlight: Highlight) throws {
        try db.execute(sql: """
            INSERT INTO highlights (id, document_id, locator_scheme, locator, quote, label, progression, color, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: highlight.arguments)
        try journal(ChangeEntity.highlight, highlight.id)
    }

    func update(_ highlight: Highlight) throws {
        var arguments = highlight.arguments
        _ = arguments.append(contentsOf: [highlight.id.stringValue])
        try db.execute(sql: """
            UPDATE highlights SET id = ?, document_id = ?, locator_scheme = ?, locator = ?, quote = ?, label = ?, progression = ?,
                color = ?, created_at = ?, updated_at = ?
            WHERE id = ?
            """, arguments: arguments)
        try requireChange("highlight \(highlight.id)")
        try journal(ChangeEntity.highlight, highlight.id)
    }

    func delete(_ id: HighlightID) throws {
        try db.execute(sql: "DELETE FROM highlights WHERE id = ?", arguments: [id.stringValue])
        try journal(ChangeEntity.highlight, id)
    }
}

extension SQLiteTransaction: LinkTargetRepository {
    func linkTarget(_ id: LinkTargetID) throws -> LinkTarget? {
        try Row.fetchOne(db, sql: "SELECT * FROM link_targets WHERE id = ?", arguments: [id.stringValue]).map(LinkTarget.init(row:))
    }

    func linkTargets(in documentID: DocumentID) throws -> [LinkTarget] {
        try Row.fetchAll(db, sql: "SELECT * FROM link_targets WHERE document_id = ? ORDER BY IFNULL(progression, 0), id",
                         arguments: [documentID.stringValue]).map(LinkTarget.init(row:))
    }

    func linkTarget(in documentID: DocumentID, at locator: Locator) throws -> LinkTarget? {
        try Row.fetchOne(db, sql: "SELECT * FROM link_targets WHERE document_id = ? AND locator_scheme = ? AND locator = ?",
                         arguments: [documentID.stringValue, locator.scheme.rawValue, locator.value]).map(LinkTarget.init(row:))
    }

    func orphanedLinkTargets(since cutoff: Date) throws -> [LinkTarget] {
        try Row.fetchAll(db, sql: "SELECT * FROM link_targets WHERE orphaned_since IS NOT NULL AND orphaned_since <= ? ORDER BY id",
                         arguments: [Columns.date(cutoff)]).map(LinkTarget.init(row:))
    }

    func insert(_ target: LinkTarget) throws {
        try db.execute(sql: """
            INSERT INTO link_targets (id, document_id, locator_scheme, locator, quote, label, progression, created_at, updated_at, orphaned_since)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: target.arguments)
        try journal(ChangeEntity.linkTarget, target.id)
    }

    func update(_ target: LinkTarget) throws {
        var arguments = target.arguments
        _ = arguments.append(contentsOf: [target.id.stringValue])
        try db.execute(sql: """
            UPDATE link_targets SET id = ?, document_id = ?, locator_scheme = ?, locator = ?, quote = ?, label = ?, progression = ?,
                created_at = ?, updated_at = ?, orphaned_since = ?
            WHERE id = ?
            """, arguments: arguments)
        try requireChange("link target \(target.id)")
        try journal(ChangeEntity.linkTarget, target.id)
    }

    func delete(_ id: LinkTargetID) throws {
        try db.execute(sql: "DELETE FROM link_targets WHERE id = ?", arguments: [id.stringValue])
        try journal(ChangeEntity.linkTarget, id)
    }
}

// MARK: References, trash, settings, positions, covers, tombstones

extension SQLiteTransaction: ReferenceRepository {
    func references(from pageID: PageID) throws -> Set<ReferenceTarget> {
        let rows = try Row.fetchAll(db, sql: "SELECT kind, ref_id FROM page_refs WHERE page_id = ?", arguments: [pageID.stringValue])
        return Set(rows.compactMap { ReferenceTarget(kind: $0["kind"], id: $0["ref_id"]) })
    }

    func referringPages(to target: ReferenceTarget) throws -> [PageID] {
        let (kind, id) = target.columns
        return try String.fetchAll(db, sql: "SELECT page_id FROM page_refs WHERE kind = ? AND ref_id = ? ORDER BY page_id",
                                   arguments: [kind, id]).compactMap(PageID.init)
    }

    func setReferences(_ targets: Set<ReferenceTarget>, from pageID: PageID) throws {
        try db.execute(sql: "DELETE FROM page_refs WHERE page_id = ?", arguments: [pageID.stringValue])
        for target in targets {
            let (kind, id) = target.columns
            try db.execute(sql: "INSERT OR IGNORE INTO page_refs (page_id, kind, ref_id) VALUES (?, ?, ?)",
                           arguments: [pageID.stringValue, kind, id])
        }
    }

    func removeAllReferences() throws {
        try db.execute(sql: "DELETE FROM page_refs")
    }
}

extension SQLiteTransaction: TrashRepository {
    func trashEntries() throws -> [TrashEntry] {
        try Row.fetchAll(db, sql: "SELECT * FROM trash_entries ORDER BY trashed_at DESC, id DESC").map(TrashEntry.init(row:))
    }

    func trashEntry(_ id: TrashEntryID) throws -> TrashEntry? {
        try Row.fetchOne(db, sql: "SELECT * FROM trash_entries WHERE id = ?", arguments: [id.stringValue]).map(TrashEntry.init(row:))
    }

    func insert(_ entry: TrashEntry) throws {
        try db.execute(sql: "INSERT INTO trash_entries (id, kind, entity_id, document_id, title, trashed_at) VALUES (?, ?, ?, ?, ?, ?)",
                       arguments: [entry.id.stringValue, entry.kind.rawValue, entry.entityID, entry.documentID?.stringValue, entry.title,
                                   Columns.date(entry.trashedAt)])
        try journal(ChangeEntity.trash, entry.id)
    }

    func delete(_ id: TrashEntryID) throws {
        try db.execute(sql: "DELETE FROM trash_entries WHERE id = ?", arguments: [id.stringValue])
        try journal(ChangeEntity.trash, id)
    }
}

extension SQLiteTransaction: SettingsRepository {
    func rawSetting(_ key: String) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
    }

    func setRawSetting(_ value: Data?, for key: String, at date: Date) throws {
        if let value {
            try db.execute(sql: "INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
                           arguments: [key, value, Columns.date(date)])
        } else {
            try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
        }
        try journal(ChangeEntity.setting, key)
    }
}

extension SQLiteTransaction: ReadingPositionRepository {
    func readingPosition(of documentID: DocumentID) throws -> ReadingPosition? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM reading_positions WHERE document_id = ?", arguments: [documentID.stringValue]) else { return nil }
        return ReadingPosition(documentID: documentID, locator: Locator(scheme: LocatorScheme(row["locator_scheme"] as String), value: row["locator"]),
                               progression: row["progression"], label: row["label"], updatedAt: Columns.date(row, "updated_at"))
    }

    func save(_ position: ReadingPosition) throws {
        try db.execute(sql: """
            INSERT INTO reading_positions (document_id, locator_scheme, locator, progression, label, updated_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(document_id) DO UPDATE SET locator_scheme = excluded.locator_scheme, locator = excluded.locator,
                progression = excluded.progression, label = excluded.label, updated_at = excluded.updated_at
            """, arguments: [position.documentID.stringValue, position.locator.scheme.rawValue, position.locator.value, position.progression,
                             position.label, Columns.date(position.updatedAt)])
        try journal(ChangeEntity.readingPosition, position.documentID)
    }

    func deleteReadingPosition(of documentID: DocumentID) throws {
        try db.execute(sql: "DELETE FROM reading_positions WHERE document_id = ?", arguments: [documentID.stringValue])
    }
}

extension SQLiteTransaction: CoverRepository {
    func derivedCover(of documentID: DocumentID) throws -> CoverImage? {
        try Row.fetchOne(db, sql: "SELECT data, mime_type FROM derived_covers WHERE document_id = ?", arguments: [documentID.stringValue])
            .map { CoverImage(data: $0["data"], mimeType: $0["mime_type"]) }
    }

    func setDerivedCover(_ cover: CoverImage?, of documentID: DocumentID) throws {
        if let cover {
            try db.execute(sql: "INSERT OR REPLACE INTO derived_covers (document_id, data, mime_type) VALUES (?, ?, ?)",
                           arguments: [documentID.stringValue, cover.data, cover.mimeType])
        } else {
            try db.execute(sql: "DELETE FROM derived_covers WHERE document_id = ?", arguments: [documentID.stringValue])
        }
    }
}

extension SQLiteTransaction: TombstoneRecording {
    func recordDeletion(entity: String, id: String, at date: Date) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO tombstones (entity, id, deleted_at) VALUES (?, ?, ?)", arguments: [entity, id, Columns.date(date)])
    }
}
