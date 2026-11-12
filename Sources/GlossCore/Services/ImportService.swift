import Foundation

/// Progress of one import, for the UI and the CLI's progress line.
public enum ImportProgress: Hashable, Sendable {
    case reading
    case storing
    case indexing
    case done
}

public enum ImportOutcome: Hashable, Sendable {
    case imported(Document)
    /// The same bytes are already in the library (possibly in the trash).
    case duplicate(Document)

    public var document: Document {
        switch self {
        case .imported(let document), .duplicate(let document): document
        }
    }
}

/// Imports files: detect → hash → dedupe → store bytes → document row and root page → text
/// index → cover. Runs off the main actor; callers observe progress.
public struct ImportService: Sendable {
    let store: any LibraryStore
    let blobs: any BlobStore
    let formats: FormatRegistry
    let ids: any IDGenerator
    let time: any TimeSource

    public init(store: any LibraryStore, blobs: any BlobStore, formats: FormatRegistry, ids: any IDGenerator, time: any TimeSource) {
        self.store = store
        self.blobs = blobs
        self.formats = formats
        self.ids = ids
        self.time = time
    }

    public func importFile(at url: URL, progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> ImportOutcome {
        progress?(.reading)
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw GlossError.notFound(url.lastPathComponent)
        }
        return try await importData(data, filename: url.lastPathComponent, progress: progress)
    }

    public func importData(_ data: Data, filename: String?, progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> ImportOutcome {
        guard let format = formats.detect(prefix: data.prefix(4096), filename: filename) else {
            throw GlossError.unsupportedFormat(filename.map { ($0 as NSString).pathExtension.isEmpty ? $0 : "." + ($0 as NSString).pathExtension } ?? "this file")
        }
        let hash = ContentHash.of(data)
        if let existing = try await store.read({ try $0.documents.documents(withContentHash: hash).first }) {
            progress?(.done)
            return .duplicate(existing)
        }
        // A file the detected format can't read would become a broken book, so refuse it.
        let metadata: ImportedMetadata
        do {
            metadata = try format.readMetadata(from: data)
        } catch {
            throw GlossError.invalid("it looks damaged, so gloss couldn't read it")
        }
        progress?(.storing)
        try await blobs.put(data)

        let now = time.now()
        let fallbackTitle = filename.map { ($0 as NSString).deletingPathExtension } ?? "untitled"
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fallbackTitle
        let document = Document(id: ids.make(), kind: format.kind, title: title,
                                author: metadata.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                                contentHash: hash, fileSize: Int64(data.count), originalFilename: filename,
                                metadata: metadata.metadata, addedAt: now, updatedAt: now)
        let root = Page(id: ids.make(), documentID: document.id, parentID: nil, title: title, body: "",
                        position: 0, createdAt: now, updatedAt: now)
        try await store.write { tx in
            try tx.documents.insert(document)
            try tx.pages.insert(root)
            try LibraryIndexer.index(document, in: tx)
            try NotesIndexer.index(root, in: tx)
        }

        progress?(.indexing)
        try await DerivedDataRebuilder.indexText(of: document, data: data, formats: formats, store: store)
        try await DerivedDataRebuilder.extractCover(of: document, data: data, formats: formats, store: store)
        progress?(.done)
        return .imported(document)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
