import Foundation

// MARK: Documents

public protocol DocumentReading {
    func document(_ id: DocumentID) throws -> Document?
    func documents(_ filter: TrashFilter) throws -> [Document]
    func documents(withContentHash hash: ContentHash) throws -> [Document]
    func documents(inTrashEntry entryID: TrashEntryID) throws -> [Document]
    /// Every blob hash a document row points at (file bytes and custom covers).
    func referencedBlobHashes() throws -> Set<ContentHash>
}

public protocol DocumentRepository: DocumentReading {
    func insert(_ document: Document) throws
    func update(_ document: Document) throws
    /// Hard delete of the row only. Services remove dependents first.
    func delete(_ id: DocumentID) throws
}

// MARK: Pages

public protocol PageReading {
    func page(_ id: PageID) throws -> Page?
    func rootPage(of documentID: DocumentID) throws -> Page?
    func pages(in documentID: DocumentID, _ filter: TrashFilter) throws -> [Page]
    func children(of pageID: PageID, _ filter: TrashFilter) throws -> [Page]
    func pages(_ filter: TrashFilter) throws -> [Page]
    func pages(inTrashEntry entryID: TrashEntryID) throws -> [Page]
}

public protocol PageRepository: PageReading {
    func insert(_ page: Page) throws
    func update(_ page: Page) throws
    func delete(_ id: PageID) throws
}

// MARK: Highlights

public protocol HighlightReading {
    func highlight(_ id: HighlightID) throws -> Highlight?
    /// Ordered by passage progression, then creation.
    func highlights(in documentID: DocumentID) throws -> [Highlight]
}

public protocol HighlightRepository: HighlightReading {
    func insert(_ highlight: Highlight) throws
    func update(_ highlight: Highlight) throws
    func delete(_ id: HighlightID) throws
}

// MARK: Link targets

public protocol LinkTargetReading {
    func linkTarget(_ id: LinkTargetID) throws -> LinkTarget?
    func linkTargets(in documentID: DocumentID) throws -> [LinkTarget]
    func linkTarget(in documentID: DocumentID, at locator: Locator) throws -> LinkTarget?
    /// Targets orphaned at or before `cutoff`.
    func orphanedLinkTargets(since cutoff: Date) throws -> [LinkTarget]
}

public protocol LinkTargetRepository: LinkTargetReading {
    func insert(_ target: LinkTarget) throws
    func update(_ target: LinkTarget) throws
    func delete(_ id: LinkTargetID) throws
}

// MARK: References (derived from page bodies)

public protocol ReferenceReading {
    func references(from pageID: PageID) throws -> Set<ReferenceTarget>
    func referringPages(to target: ReferenceTarget) throws -> [PageID]
}

public protocol ReferenceRepository: ReferenceReading {
    func setReferences(_ targets: Set<ReferenceTarget>, from pageID: PageID) throws
    func removeAllReferences() throws
}

// MARK: Trash

public protocol TrashReading {
    func trashEntries() throws -> [TrashEntry]
    func trashEntry(_ id: TrashEntryID) throws -> TrashEntry?
}

public protocol TrashRepository: TrashReading {
    func insert(_ entry: TrashEntry) throws
    func delete(_ id: TrashEntryID) throws
}

// MARK: Settings

public protocol SettingsReading {
    /// JSON-encoded value for `key`.
    func rawSetting(_ key: String) throws -> Data?
}

public protocol SettingsRepository: SettingsReading {
    func setRawSetting(_ value: Data?, for key: String, at date: Date) throws
}

// MARK: Reading positions

public protocol ReadingPositionReading {
    func readingPosition(of documentID: DocumentID) throws -> ReadingPosition?
}

public protocol ReadingPositionRepository: ReadingPositionReading {
    func save(_ position: ReadingPosition) throws
    func deleteReadingPosition(of documentID: DocumentID) throws
}

// MARK: Covers (derived, rebuildable)

public struct CoverImage: Hashable, Sendable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public protocol CoverReading {
    func derivedCover(of documentID: DocumentID) throws -> CoverImage?
}

public protocol CoverRepository: CoverReading {
    func setDerivedCover(_ cover: CoverImage?, of documentID: DocumentID) throws
}

// MARK: Tombstones (for future sync)

public protocol TombstoneRecording {
    func recordDeletion(entity: String, id: String, at date: Date) throws
}
