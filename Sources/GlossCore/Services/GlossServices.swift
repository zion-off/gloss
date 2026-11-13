import Foundation

/// The core services wired over one store. Composition roots build this once; the CLI and the
/// app use the same services.
public struct GlossServices: Sendable {
    public let store: any LibraryStore
    public let blobs: any BlobStore
    public let formats: FormatRegistry
    public let ids: any IDGenerator
    public let time: any TimeSource

    public let imports: ImportService
    public let library: LibraryService
    public let pages: PageService
    public let highlights: HighlightService
    public let links: LinkService
    /// Finding passages in a book's text to link to without a reader (`gloss link`).
    public let passages: PassageFinder
    public let linkMaintenance: LinkMaintenance
    public let trash: TrashService
    public let search: SearchService
    public let rebuilder: DerivedDataRebuilder
    public let blobCollector: BlobCollector
    public let settings: SettingsService

    public init(store: any LibraryStore, blobs: any BlobStore, formats: FormatRegistry,
                ids: any IDGenerator = UUIDv7Generator(), time: any TimeSource = SystemTimeSource(),
                trashHandlers: [any TrashableEntityHandler] = TrashService.standardHandlers,
                searchSources: [any SearchSource] = SearchService.standardSources) {
        self.store = store
        self.blobs = blobs
        self.formats = formats
        self.ids = ids
        self.time = time
        imports = ImportService(store: store, blobs: blobs, formats: formats, ids: ids, time: time)
        library = LibraryService(store: store, blobs: blobs, formats: formats, time: time)
        pages = PageService(store: store, ids: ids, time: time)
        highlights = HighlightService(store: store, ids: ids, time: time)
        links = LinkService(store: store, ids: ids, time: time)
        passages = PassageFinder(store: store, blobs: blobs, formats: formats)
        linkMaintenance = LinkMaintenance(store: store, time: time)
        trash = TrashService(store: store, ids: ids, time: time, handlers: trashHandlers)
        search = SearchService(store: store, sources: searchSources)
        rebuilder = DerivedDataRebuilder(store: store, blobs: blobs, formats: formats, time: time)
        blobCollector = BlobCollector(store: store, blobs: blobs)
        settings = SettingsService(store: store, time: time)
    }

    /// Routine upkeep: purge expired trash, sweep orphaned link targets, drop unused blobs.
    public func performMaintenance() async throws {
        try await trash.purgeExpired()
        try await linkMaintenance.sweepOrphanedTargets()
        try await blobCollector.collect()
    }
}

/// Typed settings over the store.
public struct SettingsService: Sendable {
    let store: any LibraryStore
    let time: any TimeSource

    public init(store: any LibraryStore, time: any TimeSource) {
        self.store = store
        self.time = time
    }

    public func value<V>(_ key: SettingKey<V>) async throws -> V {
        try await store.read { try SettingsCodec().value(key, in: $0.settings) }
    }

    public func set<V>(_ value: V, for key: SettingKey<V>) async throws {
        let now = time.now()
        try await store.write { try SettingsCodec().set(value, for: key, in: $0.settings, at: now) }
    }

    public func reset<V>(_ key: SettingKey<V>) async throws {
        let now = time.now()
        try await store.write { try SettingsCodec().set(nil, for: key, in: $0.settings, at: now) }
    }
}
