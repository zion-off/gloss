import Foundation
import Observation
import GlossCore

/// The library's persisted settings.
public enum LibrarySettings {
    /// How the grid is ordered; one choice for every window (D-112).
    public static let sort = SettingKey<LibrarySort>("library.sort", default: .recent)
}

/// The library grid: entries, sorting, shelves, covers, and imports with progress.
@MainActor @Observable public final class LibraryModel {
    public private(set) var entries: [LibraryEntry] = []
    public private(set) var recentlyRead: [LibraryEntry] = []
    public var sort: LibrarySort = .recent {
        didSet {
            guard sort != oldValue else { return }
            scheduleReload()
            guard !syncingSort else { return }  // a synced change is already persisted
            persistSort()
        }
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
    /// Sort writes run one after another, each writing the sort current when it runs, so the
    /// newest choice always lands last (D-112).
    private var persistTask: Task<Void, Never>?
    /// Set while the sort is loaded from the store, so loads never write back.
    private var syncingSort = false

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

    // MARK: The persisted sort (one choice for every window, D-112)

    /// Loads the persisted sort (the window calls this once at startup, before the first reload).
    public func loadPersistedSort() async {
        syncingSort = true
        sort = (try? await services.settings.value(LibrarySettings.sort)) ?? .recent
        syncingSort = false
    }

    /// Re-reads the sort another window changed. The window's change poll calls this once a
    /// second (the change journal can't carry it: all windows share one process origin, so the
    /// journal skips their own writes), so every window agrees within a second.
    public func syncSort() async {
        let stored = (try? await services.settings.value(LibrarySettings.sort)) ?? .recent
        guard stored != sort else { return }
        syncingSort = true
        sort = stored  // schedules the reload, skips the persist
        syncingSort = false
    }

    private func persistSort() {
        let previous = persistTask
        persistTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            try? await self.services.settings.set(self.sort, for: LibrarySettings.sort)
        }
    }

    /// Waits for any in-flight sort persistence (tests, teardown before quit).
    public func flushSortPersistence() async {
        while let task = persistTask {
            await task.value
            if persistTask == task { break }
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
