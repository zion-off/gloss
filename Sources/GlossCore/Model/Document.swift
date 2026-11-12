import Foundation

/// Descriptive metadata read from a file at import. Unknown fields go into `extra`.
public struct DocumentMetadata: Hashable, Codable, Sendable {
    public var language: String?
    public var publisher: String?
    public var identifier: String?
    public var published: String?
    public var pageCount: Int?
    public var extra: [String: String]

    public init(language: String? = nil, publisher: String? = nil, identifier: String? = nil,
                published: String? = nil, pageCount: Int? = nil, extra: [String: String] = [:]) {
        self.language = language
        self.publisher = publisher
        self.identifier = identifier
        self.published = published
        self.pageCount = pageCount
        self.extra = extra
    }
}

/// A book or PDF in the library. Its bytes live in the `BlobStore` under `contentHash`.
public struct Document: Identifiable, Hashable, Codable, Sendable {
    public var id: DocumentID
    public var kind: DocumentKind
    public var title: String
    public var author: String
    public var contentHash: ContentHash
    public var fileSize: Int64
    public var originalFilename: String?
    /// A cover the user chose. `nil` means "use the cover from the file, or a generated one".
    public var coverHash: ContentHash?
    public var metadata: DocumentMetadata
    public var addedAt: Date
    public var updatedAt: Date
    public var lastOpenedAt: Date?
    public var trash: TrashStamp?

    public init(id: DocumentID, kind: DocumentKind, title: String, author: String,
                contentHash: ContentHash, fileSize: Int64, originalFilename: String? = nil,
                coverHash: ContentHash? = nil, metadata: DocumentMetadata = DocumentMetadata(),
                addedAt: Date, updatedAt: Date, lastOpenedAt: Date? = nil, trash: TrashStamp? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.author = author
        self.contentHash = contentHash
        self.fileSize = fileSize
        self.originalFilename = originalFilename
        self.coverHash = coverHash
        self.metadata = metadata
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
        self.trash = trash
    }

    public var isTrashed: Bool { trash != nil }
}
