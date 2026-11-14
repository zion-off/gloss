import Foundation

/// Highlights: colour on passages, independent of links.
public struct HighlightService: Sendable {
    let store: any LibraryStore
    let ids: any IDGenerator
    let time: any TimeSource

    public init(store: any LibraryStore, ids: any IDGenerator, time: any TimeSource) {
        self.store = store
        self.ids = ids
        self.time = time
    }

    public func highlights(in documentID: DocumentID) async throws -> [Highlight] {
        try await store.read { try $0.highlights.highlights(in: documentID) }
    }

    public func highlight(_ id: HighlightID) async throws -> Highlight? {
        try await store.read { try $0.highlights.highlight(id) }
    }

    @discardableResult
    public func add(_ passage: Passage, color: HighlightColor = .yellow, in documentID: DocumentID) async throws -> Highlight {
        let now = time.now()
        let highlight = Highlight(id: ids.make(), documentID: documentID, passage: passage, color: color, createdAt: now, updatedAt: now)
        try await store.write { tx in
            guard try tx.documents.document(documentID) != nil else { throw GlossError.notFound("that book") }
            try tx.highlights.insert(highlight)
        }
        return highlight
    }

    @discardableResult
    public func recolor(_ id: HighlightID, to color: HighlightColor) async throws -> Highlight {
        let now = time.now()
        return try await store.write { tx in
            guard var highlight = try tx.highlights.highlight(id) else { throw GlossError.notFound("that highlight") }
            highlight.color = color
            highlight.updatedAt = now
            try tx.highlights.update(highlight)
            return highlight
        }
    }

    /// Deletes a highlight. Never touches link targets.
    /// Returns the deleted highlight so the caller can offer undo via `restore`.
    @discardableResult
    public func delete(_ id: HighlightID) async throws -> Highlight? {
        let now = time.now()
        return try await store.write { tx in
            guard let highlight = try tx.highlights.highlight(id) else { return nil }
            try tx.highlights.delete(id)
            try tx.tombstones.recordDeletion(entity: ChangeEntity.highlight, id: id.stringValue, at: now)
            return highlight
        }
    }

    /// Undo for `delete`: puts the same highlight back.
    public func restore(_ highlight: Highlight) async throws {
        try await store.write { tx in
            if try tx.highlights.highlight(highlight.id) == nil { try tx.highlights.insert(highlight) }
        }
    }
}
