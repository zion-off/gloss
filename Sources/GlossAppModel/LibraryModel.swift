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
    /// What the most recent import found, for the "already in your library" offer (D-114).
    public private(set) var lastImport: ImportSummary?
    /// Documents added by the most recent import (for the "just added" reveal).
    public private(set) var lastImportedIDs: [DocumentID] = []
    /// Documents the most recent import found already in the library, in arrival order —
    /// a duplicate still has a destination (open the existing copy).
    public var lastDuplicates: [Document] { lastImport?.duplicates ?? [] }

    /// Documents this window's imports added: AppModel tells the app's other windows (review 7;
    /// the journal's origin is per-process, so their monitors never see them).
    public var onImported: (@MainActor ([Document]) -> Void)?

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
    /// The badge a document's kind shows on its cover (its format names it: "epub", "pdf").
    public func badge(of kind: DocumentKind) -> String { services.formats.badge(of: kind) }
    /// The extensions the registered formats read (the import panel filters to them).
    public var supportedExtensions: [String] { services.formats.supportedExtensions }

    public func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        do {
            let fetched = try await services.library.entries(sortedBy: sort, shelf: shelf)
            let recent = try await services.library.recentlyRead()
            guard generation == reloadGeneration else { return }  // a newer reload owns the result
            entries = fetched
            recentlyRead = recent
        } catch {
            // A failed read keeps what is shown (the trash and the workspace already do).
        }
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
        do {
            let stored = try await services.settings.value(LibrarySettings.sort)
            guard stored != sort else { return }
            syncingSort = true
            sort = stored  // schedules the reload, skips the persist
            syncingSort = false
        } catch {
            // A failed read keeps this window's sort; the next poll tries again.
        }
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
        var summary = ImportSummary()
        importing = true
        importStatus = nil
        defer { importing = false; importStatus = nil }
        for url in urls {
            // Folder expansion walks the disk; keep it off the main actor (like the import itself).
            let extensions = services.formats.supportedExtensions
            let files = await Task.detached(priority: .userInitiated) {
                ImportCandidates.expand(url, supportedExtensions: extensions)
            }.value
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
                        summary.imported.append(document)
                        importStatus = "added \(document.title)"
                    case .duplicate(let document):
                        summary.duplicates.append(document)
                        importStatus = "\(document.title) is already in your library"
                    }
                } catch {
                    importingFile = nil
                    summary.failures.append(ImportSummary.Failure(name: file.lastPathComponent, reason: Self.describe(error)))
                    importStatus = "couldn't read \(file.lastPathComponent): \(Self.describe(error))"
                }
            }
        }
        lastImportedIDs = summary.imported.map(\.id)
        lastImport = summary
        onImported?(summary.imported)
        await reload()
        return summary.imported
    }

    static func describe(_ error: any Error) -> String {
        (error as? GlossError)?.description ?? "something went wrong"
    }
}

/// What an import found, so the view can offer to open duplicates and name failures (D-114).
/// The copy it shows is built here, portable and tested: the view only presents it.
public struct ImportSummary: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public var name: String
        public var reason: String
    }

    /// Set by `LibraryModel` while an import runs; read by the view.
    public internal(set) var imported: [Document] = []
    public internal(set) var duplicates: [Document] = []
    public internal(set) var failures: [Failure] = []

    init() {}

    /// Whether anything needs saying once the import ends.
    public var hasNews: Bool { !duplicates.isEmpty || !failures.isEmpty }

    /// The alert's title.
    public var alertTitle: String {
        if duplicates.isEmpty, imported.isEmpty { return "couldn't import" }
        return failures.isEmpty ? "already in your library" : "import finished"
    }

    /// The alert's message: what was already there, and what couldn't be read.
    public var alertMessage: String {
        var parts: [String] = []
        switch duplicates.count {
        case 0: break
        case 1: parts.append("“\(duplicates[0].title)” is already in your library.")
        default: parts.append("\(duplicates.count) of these are already in your library.")
        }
        for failure in failures {
            parts.append("couldn't read \(failure.name): \(failure.reason).")
        }
        return parts.joined(separator: "\n")
    }

    /// The "open the existing copy" action's title.
    public var openActionTitle: String { duplicates.count == 1 ? "open it" : "open them" }
}

