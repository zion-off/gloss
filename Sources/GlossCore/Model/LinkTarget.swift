import Foundation

/// A passage that notes can link to with `gloss://passage/<id>`.
public struct LinkTarget: Identifiable, Hashable, Codable, Sendable {
    public var id: LinkTargetID
    public var documentID: DocumentID
    public var passage: Passage
    public var createdAt: Date
    public var updatedAt: Date
    /// Set when the last page referencing this target stopped doing so; cleared when a page
    /// references it again. Old orphans are swept.
    public var orphanedSince: Date?

    public init(id: LinkTargetID, documentID: DocumentID, passage: Passage, createdAt: Date,
                updatedAt: Date, orphanedSince: Date? = nil) {
        self.id = id
        self.documentID = documentID
        self.passage = passage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.orphanedSince = orphanedSince
    }
}
