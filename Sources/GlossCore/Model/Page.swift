import Foundation

/// A notes page. Each document has one root page (no parent) and any number of subpages.
/// `body` is the raw markdown exactly as typed; nothing parses and re-serialises it.
public struct Page: Identifiable, Hashable, Codable, Sendable {
    public var id: PageID
    public var documentID: DocumentID
    public var parentID: PageID?
    public var title: String
    public var body: String
    /// Sibling order (creation order in v1; the outline is read-only).
    public var position: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var trash: TrashStamp?

    public init(id: PageID, documentID: DocumentID, parentID: PageID?, title: String, body: String,
                position: Double, createdAt: Date, updatedAt: Date, trash: TrashStamp? = nil) {
        self.id = id
        self.documentID = documentID
        self.parentID = parentID
        self.title = title
        self.body = body
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.trash = trash
    }

    public var isRoot: Bool { parentID == nil }
    public var isTrashed: Bool { trash != nil }
}
