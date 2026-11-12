import Foundation

/// The five highlight colours. Colour never affects notes.
public enum HighlightColor: String, CaseIterable, Codable, Sendable {
    case yellow, green, blue, pink, purple
}

/// A coloured passage. Independent of link targets: deleting one never touches the other.
public struct Highlight: Identifiable, Hashable, Codable, Sendable {
    public var id: HighlightID
    public var documentID: DocumentID
    public var passage: Passage
    public var color: HighlightColor
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: HighlightID, documentID: DocumentID, passage: Passage, color: HighlightColor,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.documentID = documentID
        self.passage = passage
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
