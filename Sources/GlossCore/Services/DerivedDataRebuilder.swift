import Foundation

/// Rebuilds everything derived (search indexes, references, covers) from the authoritative
/// rows and blobs. Derived data is never synced; this is how it is restored anywhere.
public struct DerivedDataRebuilder: Sendable {
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

    public struct Report: Hashable, Sendable {
        public var documents = 0
        public var pages = 0
        public var textChunks = 0
    }

    /// Rebuilds notes and library indexes plus references, then book text and covers.
    @discardableResult
    public func rebuildAll(progress: (@Sendable (String) -> Void)? = nil) async throws -> Report {
        let now = time.now()
        progress?("notes and links")
        var report = try await store.write { tx in
            try tx.references.removeAllReferences()
            try tx.fullText.removeAllEntries(corpus: .notes)
            try tx.fullText.removeAllEntries(corpus: .library)
            var report = Report()
            for page in try tx.pages.pages(.any) {
                try NotesIndexer.index(page, in: tx)
                try tx.references.setReferences(ReferenceExtractor.references(in: page.body), from: page.id)
                report.pages += 1
            }
            for document in try tx.documents.documents(.any) {
                try LibraryIndexer.index(document, in: tx)
                report.documents += 1
            }
            // Re-derive orphan marks from the fresh references.
            for document in try tx.documents.documents(.any) {
                for var target in try tx.linkTargets.linkTargets(in: document.id) {
                    let referenced = !(try tx.references.referringPages(to: .passage(target.id)).isEmpty)
                    if referenced, target.orphanedSince != nil { target.orphanedSince = nil; try tx.linkTargets.update(target) }
                    if !referenced, target.orphanedSince == nil { target.orphanedSince = now; try tx.linkTargets.update(target) }
                }
            }
            return report
        }
        let documents = try await store.read { try $0.documents.documents(.any) }
        for document in documents {
            progress?(document.title)
            guard let data = try await blobs.data(for: document.contentHash) else { continue }
            report.textChunks += try await Self.indexText(of: document, data: data, formats: formats, store: store)
            try await store.write { try $0.covers.setDerivedCover(nil, of: document.id) }
            try await Self.extractCover(of: document, data: data, formats: formats, store: store)
        }
        return report
    }

    /// Extracts and indexes a document's text. Extraction failures leave the book unsearchable
    /// rather than failing the import.
    @discardableResult
    static func indexText(of document: Document, data: Data, formats: FormatRegistry, store: any LibraryStore) async throws -> Int {
        guard let extractor = formats.textExtractor(for: document.kind),
              let chunks = try? extractor.extractText(from: data) else { return 0 }
        try await store.write { tx in try BookTextIndexer.index(chunks, of: document, in: tx) }
        return chunks.count
    }

    /// Extracts a cover with the registered extractors and caches it.
    @discardableResult
    static func extractCover(of document: Document, data: Data, formats: FormatRegistry, store: any LibraryStore) async throws -> CoverImage? {
        for extractor in formats.coverExtractors(for: document.kind) {
            if let cover = try? extractor.extractCover(from: data) {
                try await store.write { tx in try tx.covers.setDerivedCover(cover, of: document.id) }
                return cover
            }
        }
        return nil
    }
}

/// Deletes blobs no document points at any more.
public struct BlobCollector: Sendable {
    let store: any LibraryStore
    let blobs: any BlobStore

    public init(store: any LibraryStore, blobs: any BlobStore) {
        self.store = store
        self.blobs = blobs
    }

    @discardableResult
    public func collect() async throws -> Int {
        let referenced = try await store.read { try $0.documents.referencedBlobHashes() }
        let unreferenced = try await blobs.allHashes().subtracting(referenced)
        for hash in unreferenced { try await blobs.delete(hash) }
        return unreferenced.count
    }
}
