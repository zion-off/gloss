import Foundation

/// Where the reader last was in a document.
public struct ReadingPosition: Hashable, Codable, Sendable {
    public var documentID: DocumentID
    public var locator: Locator
    public var progression: Double
    public var label: String?
    public var updatedAt: Date

    public init(documentID: DocumentID, locator: Locator, progression: Double, label: String? = nil, updatedAt: Date) {
        self.documentID = documentID
        self.locator = locator
        self.progression = min(1, max(0, progression))
        self.label = label
        self.updatedAt = updatedAt
    }
}
