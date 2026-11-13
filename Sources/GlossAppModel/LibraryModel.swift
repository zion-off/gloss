import Foundation
import Observation
import GlossCore

/// The library grid: entries, sorting, shelves, covers, and imports with progress.
@MainActor @Observable public final class LibraryModel {
    public private(set) var entries: [LibraryEntry] = []
    public private(set) var recentlyRead: [LibraryEntry] = []
    public var sort: LibrarySort = .recent {
        didSet { scheduleReload() }
    }
    public var shelf: LibraryShelf? {
        didSet { scheduleReload() }
    }
    public private(set) var importing = false
    /// What an in-flight import is doing ("reading moby.epub…").
    public private(set) var importStatus: String?
    /// Documents added by the most recent import (for the "just added" reveal).
    public private(set) var lastImportedIDs: [DocumentID] = []

    private let services: GlossServices
    private let shelves: [LibraryShelf]
    private var coverCache: [DocumentID: CoverImage] = [:]
    private var reloadTask: Task<Void, Never>?
    /// Bumped by every reload; only the newest reload may publish its results.
    private var reloadGeneration = 0
    /// The file whose progress may update `importStatus` (late callbacks are dropped).
    private var importingFile: URL?

    public init(services: GlossServices) {
        self.services = services
        self.shelves = services.formats.shelves
    }

    public var availableShelves: [LibraryShelf] { shelves }

    /// The source list's symbol for a shelf (its format names it).
    public func symbol(of shelf: LibraryShelf) -> String { services.formats.symbol(of: shelf) }
    /// The symbol of a document of this kind (its format names it).
    public func symbol(of kind: DocumentKind) -> String { services.formats.symbol(of: kind) }

    public func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let fetched = (try? await services.library.entries(sortedBy: sort, shelf: shelf)) ?? []
        let recent = (try? await services.library.recentlyRead()) ?? []
        guard generation == reloadGeneration else { return }  // a newer reload owns the result
        entries = fetched
        recentlyRead = recent
    }

    private func scheduleReload() {
        reloadTask = Task { [weak self] in await self?.reload() }
    }

    /// Waits for a reload started by changing `sort` or `shelf`.
    public func settle() async {
        while let task = reloadTask {
            await task.value
            if reloadTask == task { break }
        }
    }

    /// Cover for a document, cached (the grid asks for many).
    public func cover(of id: DocumentID) async -> CoverImage? {
        if let cached = coverCache[id] { return cached }
        guard let cover = try? await services.library.cover(of: id) else { return nil }
        coverCache[id] = cover
        return cover
    }

    /// Invalidates cached state for documents that changed (external changes, restores).
    public func invalidate(ids: [DocumentID]) async {
        for id in ids { coverCache[id] = nil }
        await reload()
    }

    public func invalidateAll() async {
        coverCache.removeAll()
        await reload()
    }

    // MARK: Import

    /// Imports files (and folders, recursively) with one progress line.
    @discardableResult
    public func importFiles(at urls: [URL]) async -> [Document] {
        var imported: [Document] = []
        importing = true
        importStatus = nil
        defer { importing = false; importStatus = nil }
        for url in urls {
            let files = ImportCandidates.expand(url, supportedExtensions: services.formats.supportedExtensions)
            for file in files {
                importStatus = "reading \(file.lastPathComponent)…"
                importingFile = file
                defer { importingFile = nil }
                do {
                    let outcome = try await services.imports.importFile(at: file) { [weak self] progress in
                        Task { @MainActor in
                            guard let self, self.importingFile == file else { return }
                            switch progress {
                            case .storing: self.importStatus = "storing \(file.lastPathComponent)…"
                            case .indexing: self.importStatus = "indexing \(file.lastPathComponent)…"
                            default: break
                            }
                        }
                    }
                    importingFile = nil
                    switch outcome {
                    case .imported(let document):
                        imported.append(document)
                        importStatus = "added \(document.title)"
                    case .duplicate(let document):
                        importStatus = "\(document.title) is already in your library"
                    }
                } catch {
                    importingFile = nil
                    importStatus = "couldn't read \(file.lastPathComponent): \(Self.describe(error))"
                }
            }
        }
        lastImportedIDs = imported.map(\.id)
        await reload()
        return imported
    }

    static func describe(_ error: any Error) -> String {
        (error as? GlossError)?.description ?? "something went wrong"
    }
}
