import Foundation
import GlossCore
import GRDB

/// Conversions between rows and core values. Dates are stored as REAL unix seconds.
enum Columns {
    static func date(_ value: Date) -> Double { value.timeIntervalSince1970 }
    static func optionalDate(_ value: Date?) -> Double? { value?.timeIntervalSince1970 }
    static func date(_ row: Row, _ column: String) -> Date { Date(timeIntervalSince1970: row[column]) }
    static func optionalDate(_ row: Row, _ column: String) -> Date? {
        (row[column] as Double?).map(Date.init(timeIntervalSince1970:))
    }

    static func id<T>(_ row: Row, _ column: String) throws -> Identifier<T> {
        let raw: String = row[column]
        guard let id = Identifier<T>(raw) else { throw StoreError.conflict("bad id in \(column): \(raw)") }
        return id
    }

    static func optionalID<T>(_ row: Row, _ column: String) throws -> Identifier<T>? {
        guard let raw = row[column] as String? else { return nil }
        guard let id = Identifier<T>(raw) else { throw StoreError.conflict("bad id in \(column): \(raw)") }
        return id
    }

    static func hash(_ row: Row, _ column: String) throws -> ContentHash {
        guard let hash = ContentHash(hex: row[column]) else { throw StoreError.conflict("bad hash in \(column)") }
        return hash
    }

    static func trash(_ row: Row) throws -> TrashStamp? {
        guard let entry: TrashEntryID = try optionalID(row, "trash_entry"), let at = optionalDate(row, "trashed_at") else { return nil }
        return TrashStamp(entryID: entry, trashedAt: at)
    }

    static func passage(_ row: Row) -> Passage {
        Passage(locator: Locator(scheme: LocatorScheme(row["locator_scheme"] as String), value: row["locator"]),
                quote: row["quote"], label: row["label"], progression: row["progression"])
    }
}

extension Document {
    init(row: Row) throws {
        let metadataJSON: String = row["metadata"]
        self.init(id: try Columns.id(row, "id"), kind: DocumentKind(row["kind"] as String), title: row["title"], author: row["author"],
                  contentHash: try Columns.hash(row, "content_hash"), fileSize: row["file_size"],
                  originalFilename: row["original_filename"],
                  coverHash: (row["cover_hash"] as String?).flatMap(ContentHash.init(hex:)),
                  metadata: (try? JSONDecoder().decode(DocumentMetadata.self, from: Data(metadataJSON.utf8))) ?? DocumentMetadata(),
                  addedAt: Columns.date(row, "added_at"), updatedAt: Columns.date(row, "updated_at"),
                  lastOpenedAt: Columns.optionalDate(row, "last_opened_at"), trash: try Columns.trash(row))
    }

    var arguments: StatementArguments {
        let metadataJSON = (try? JSONEncoder().encode(metadata)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return [id.stringValue, kind.rawValue, title, author, contentHash.hex, fileSize, originalFilename, coverHash?.hex, metadataJSON,
                Columns.date(addedAt), Columns.date(updatedAt), Columns.optionalDate(lastOpenedAt), trash?.entryID.stringValue,
                Columns.optionalDate(trash?.trashedAt)]
    }
}

extension Page {
    init(row: Row) throws {
        self.init(id: try Columns.id(row, "id"), documentID: try Columns.id(row, "document_id"), parentID: try Columns.optionalID(row, "parent_id"),
                  title: row["title"], body: row["body"], position: row["position"],
                  createdAt: Columns.date(row, "created_at"), updatedAt: Columns.date(row, "updated_at"), trash: try Columns.trash(row))
    }

    var arguments: StatementArguments {
        [id.stringValue, documentID.stringValue, parentID?.stringValue, title, body, position, Columns.date(createdAt),
         Columns.date(updatedAt), trash?.entryID.stringValue, Columns.optionalDate(trash?.trashedAt)]
    }
}

extension Highlight {
    init(row: Row) throws {
        self.init(id: try Columns.id(row, "id"), documentID: try Columns.id(row, "document_id"), passage: Columns.passage(row),
                  color: HighlightColor(rawValue: row["color"]) ?? .yellow,
                  createdAt: Columns.date(row, "created_at"), updatedAt: Columns.date(row, "updated_at"))
    }

    var arguments: StatementArguments {
        [id.stringValue, documentID.stringValue, passage.locator.scheme.rawValue, passage.locator.value, passage.quote, passage.label,
         passage.progression, color.rawValue, Columns.date(createdAt), Columns.date(updatedAt)]
    }
}

extension LinkTarget {
    init(row: Row) throws {
        self.init(id: try Columns.id(row, "id"), documentID: try Columns.id(row, "document_id"), passage: Columns.passage(row),
                  createdAt: Columns.date(row, "created_at"), updatedAt: Columns.date(row, "updated_at"),
                  orphanedSince: Columns.optionalDate(row, "orphaned_since"))
    }

    var arguments: StatementArguments {
        [id.stringValue, documentID.stringValue, passage.locator.scheme.rawValue, passage.locator.value, passage.quote, passage.label,
         passage.progression, Columns.date(createdAt), Columns.date(updatedAt), Columns.optionalDate(orphanedSince)]
    }
}

extension TrashEntry {
    init(row: Row) throws {
        self.init(id: try Columns.id(row, "id"), kind: TrashableKind(row["kind"] as String), entityID: row["entity_id"],
                  documentID: try Columns.optionalID(row, "document_id"), title: row["title"], trashedAt: Columns.date(row, "trashed_at"))
    }
}

extension ReferenceTarget {
    var columns: (kind: String, id: String) {
        switch self {
        case .passage(let id): ("passage", id.stringValue)
        case .page(let id): ("page", id.stringValue)
        case .document(let id): ("document", id.stringValue)
        }
    }

    init?(kind: String, id: String) {
        guard let raw = GlossID(string: id) else { return nil }
        switch kind {
        case "passage": self = .passage(LinkTargetID(raw))
        case "page": self = .page(PageID(raw))
        case "document": self = .document(DocumentID(raw))
        default: return nil
        }
    }
}
