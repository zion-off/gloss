import Foundation

/// Marks a row as being in the trash, as part of one trash batch (= one `TrashEntry`).
public struct TrashStamp: Hashable, Codable, Sendable {
    public var entryID: TrashEntryID
    public var trashedAt: Date

    public init(entryID: TrashEntryID, trashedAt: Date) {
        self.entryID = entryID
        self.trashedAt = trashedAt
    }
}

/// What kind of thing a trash entry holds. Open: new deletable entities register a handler
/// for their own kind (see `TrashableEntityHandler`).
public struct TrashableKind: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let document = TrashableKind("document")
    public static let page = TrashableKind("page")
}

/// One user-visible item in the trash: the thing the user deleted. Everything that was
/// cascaded along with it carries the same entry in its `TrashStamp`.
public struct TrashEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: TrashEntryID
    public var kind: TrashableKind
    public var entityID: String
    public var documentID: DocumentID?
    public var title: String
    public var trashedAt: Date

    public init(id: TrashEntryID, kind: TrashableKind, entityID: String, documentID: DocumentID?, title: String, trashedAt: Date) {
        self.id = id
        self.kind = kind
        self.entityID = entityID
        self.documentID = documentID
        self.title = title
        self.trashedAt = trashedAt
    }
}

/// Which rows a query should see.
public enum TrashFilter: Sendable {
    case live
    case trashed
    case any

    public func admits(_ stamp: TrashStamp?) -> Bool {
        switch self {
        case .live: stamp == nil
        case .trashed: stamp != nil
        case .any: true
        }
    }
}
