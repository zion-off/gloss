import Foundation

/// How the library grid is ordered.
public enum LibrarySort: String, CaseIterable, Codable, Sendable {
    case recent, title, author, dateAdded

    public func sorted(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        entries.sorted { a, b in
            switch self {
            case .recent:
                let left = a.document.lastOpenedAt ?? a.document.addedAt
                let right = b.document.lastOpenedAt ?? b.document.addedAt
                return left != right ? left > right : a.document.id < b.document.id
            case .title:
                return Self.ordered(a.document.title, b.document.title) ?? (a.document.id < b.document.id)
            case .author:
                return Self.ordered(a.document.author, b.document.author)
                    ?? Self.ordered(a.document.title, b.document.title) ?? (a.document.id < b.document.id)
            case .dateAdded:
                return a.document.addedAt != b.document.addedAt ? a.document.addedAt > b.document.addedAt : a.document.id < b.document.id
            }
        }
    }

    /// Case- and diacritic-insensitive comparison, ignoring a leading "the"/"a"/"an";
    /// empty values sort last. Nil when equal.
    static func ordered(_ a: String, _ b: String) -> Bool? {
        let left = sortKey(a), right = sortKey(b)
        if left == right { return nil }
        if left.isEmpty { return false }
        if right.isEmpty { return true }
        return left < right
    }

    static func sortKey(_ value: String) -> String {
        var key = TextMatcher.fold(value.trimmingCharacters(in: .whitespaces))
        for article in ["the ", "a ", "an "] where key.hasPrefix(article) {
            key.removeFirst(article.count)
            break
        }
        return key
    }
}

/// A document with its reading progress, as the library shows it.
public struct LibraryEntry: Hashable, Sendable, Identifiable {
    public var document: Document
    public var position: ReadingPosition?

    public var id: DocumentID { document.id }
    public var progress: Double { position?.progression ?? 0 }
}

/// The library: listing, details, covers, file bytes and reading positions.
public struct LibraryService: Sendable {
    let store: any LibraryStore
    let blobs: any BlobStore
    let formats: FormatRegistry
    let time: any TimeSource

    public init(store: any LibraryStore, blobs: any BlobStore, formats: FormatRegistry, time: any TimeSource) {
        self.store = store
        self.blobs = blobs
        self.formats = formats
        self.time = time
    }

    public func entries(sortedBy sort: LibrarySort = .recent, shelf: LibraryShelf? = nil) async throws -> [LibraryEntry] {
        let formats = formats
        let entries = try await store.read { tx in
            try tx.documents.documents(.live)
                .filter { shelf == nil || formats.shelf(of: $0.kind) == shelf }
                .map { LibraryEntry(document: $0, position: try tx.readingPositions.readingPosition(of: $0.id)) }
        }
        return sort.sorted(entries)
    }

    /// The "recently read" shelf: opened documents, most recent first.
    public func recentlyRead(limit: Int = 10) async throws -> [LibraryEntry] {
        let opened = try await entries(sortedBy: .recent).filter { $0.document.lastOpenedAt != nil }
        return Array(opened.prefix(limit))
    }

    public func document(_ id: DocumentID) async throws -> Document? {
        try await store.read { try $0.documents.document(id) }
    }

    /// Edits title and/or author. The root page follows a rename when it still carried the old
    /// title.
    @discardableResult
    public func updateDetails(_ id: DocumentID, title: String? = nil, author: String? = nil) async throws -> Document {
        let now = time.now()
        return try await store.write { tx in
            guard var document = try tx.documents.document(id) else { throw GlossError.notFound("that book") }
            let oldTitle = document.title
            if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { document.title = title }
            if let author { document.author = author.trimmingCharacters(in: .whitespacesAndNewlines) }
            document.updatedAt = now
            try tx.documents.update(document)
            try LibraryIndexer.index(document, in: tx)
            if document.title != oldTitle, var root = try tx.pages.rootPage(of: id), root.title == oldTitle {
                root.title = document.title
                root.updatedAt = now
                try tx.pages.update(root)
                try NotesIndexer.index(root, in: tx)
            }
            return document
        }
    }

    /// Sets a custom cover from image bytes, or reverts to the file's cover with `nil`.
    @discardableResult
    public func setCover(_ id: DocumentID, imageData: Data?) async throws -> Document {
        let hash = try await imageData.asyncMap { try await blobs.put($0) }
        let now = time.now()
        return try await store.write { tx in
            guard var document = try tx.documents.document(id) else { throw GlossError.notFound("that book") }
            document.coverHash = hash
            document.updatedAt = now
            try tx.documents.update(document)
            return document
        }
    }

    /// The best cover available: custom, then cached from the file, then freshly extracted.
    /// `nil` means "draw a generated cover".
    public func cover(of id: DocumentID) async throws -> CoverImage? {
        guard let document = try await document(id) else { return nil }
        if let hash = document.coverHash, let data = try await blobs.data(for: hash) {
            return CoverImage(data: data, mimeType: CoverImage.sniffMimeType(data))
        }
        if let cached = try await store.read({ try $0.covers.derivedCover(of: id) }) { return cached }
        guard let data = try await blobs.data(for: document.contentHash) else { return nil }
        return try await DerivedDataRebuilder.extractCover(of: document, data: data, formats: formats, store: store)
    }

    /// The document's file bytes.
    public func fileData(of id: DocumentID) async throws -> Data {
        guard let document = try await document(id) else { throw GlossError.notFound("that book") }
        guard let data = try await blobs.data(for: document.contentHash) else { throw GlossError.notFound("the file for \(document.title)") }
        return data
    }

    public func markOpened(_ id: DocumentID) async throws {
        let now = time.now()
        try await store.write { tx in
            guard var document = try tx.documents.document(id) else { return }
            document.lastOpenedAt = now
            try tx.documents.update(document)
        }
    }

    public func position(of id: DocumentID) async throws -> ReadingPosition? {
        try await store.read { try $0.readingPositions.readingPosition(of: id) }
    }

    public func savePosition(_ locator: Locator, progression: Double, label: String?, of id: DocumentID) async throws {
        let position = ReadingPosition(documentID: id, locator: locator, progression: progression, label: label, updatedAt: time.now())
        try await store.write { tx in try tx.readingPositions.save(position) }
    }
}

extension CoverImage {
    /// Guesses an image MIME type from magic bytes.
    public static func sniffMimeType(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.count >= 12, bytes[0..<4].elementsEqual(Array("RIFF".utf8)), bytes[8..<12].elementsEqual(Array("WEBP".utf8)) { return "image/webp" }
        if let text = String(data: data.prefix(256), encoding: .utf8), text.contains("<svg") { return "image/svg+xml" }
        return "application/octet-stream"
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
