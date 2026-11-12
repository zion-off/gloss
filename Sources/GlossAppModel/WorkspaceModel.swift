import Foundation
import GlossCore
import Observation

/// Where the reader pane is, including the passage to jump to.
public struct ReaderFocus: Hashable, Sendable {
    public var documentID: DocumentID
    /// A passage or position to scroll to once the book is open.
    public var locator: Locator?

    public init(documentID: DocumentID, locator: Locator? = nil) {
        self.documentID = documentID
        self.locator = locator
    }
}

/// One window's state: the open book, the open notes page, the split layout, and back/forward
/// history per pane (⌘[ / ⌘]). @MainActor: the UI owns it; every mutation is a user action.
@MainActor @Observable public final class WorkspaceModel {
    public private(set) var document: Document?
    public private(set) var page: Page?
    public var layout: SplitLayout {
        didSet {
            // Loads must not write back (a stale load would clobber a newer persist).
            guard !suppressLayoutPersist, layout != oldValue else { return }
            // Writes are chained so they land in order, and each writes the layout current
            // when it runs: the last change always wins.
            let previous = persistTask
            persistTask = Task { [weak self] in
                await previous?.value
                await self?.persistLayout()
            }
        }
    }
    private var persistTask: Task<Void, Never>?
    private var suppressLayoutPersist = false

    public private(set) var readerHistory = NavigationHistory<ReaderFocus>()
    public private(set) var notesHistory = NavigationHistory<PageID>()
    public var canGoBackInReader: Bool { readerHistory.canGoBack }
    public var canGoForwardInReader: Bool { readerHistory.canGoForward }
    public var canGoBackInNotes: Bool { notesHistory.canGoBack }
    public var canGoForwardInNotes: Bool { notesHistory.canGoForward }

    /// Where the reader pane should be right now (the engine reacts to changes).
    public private(set) var readerFocus: ReaderFocus?
    /// A passage link the reader should flash once it lands (set by routing).
    public private(set) var pendingPassage: LinkTargetID?
    /// A range in the open page the editor should select and scroll to (a marker click).
    public private(set) var pendingNoteReveal: Range<Int>?

    private let services: GlossServices
    private let persistLayoutSetting: Bool

    public init(services: GlossServices, layout: SplitLayout = .split, persistLayoutSetting: Bool = true) {
        self.services = services
        self.layout = layout
        self.persistLayoutSetting = persistLayoutSetting
    }

    // MARK: Opening

    /// Opens a book (reader pane) and shows its root notes page (notes pane).
    public func openDocument(_ id: DocumentID, locator: Locator? = nil) async throws {
        guard let document = try await services.library.document(id), document.trash == nil else {
            throw GlossError.notFound("that book")
        }
        self.document = document
        try await services.library.markOpened(id)
        if page?.documentID != id {
            page = try await services.pages.rootPage(of: id)
            if let page { notesHistory.visit(page.id) }
        }
        readerHistory.visit(ReaderFocus(documentID: id, locator: locator))
        readerFocus = readerHistory.current
        pendingPassage = nil
    }

    /// Opens a notes page at a range (from a marker click), revealing the panel if hidden.
    public func openPage(_ id: PageID, revealing range: Range<Int>?) async throws {
        try await openPage(id)
        pendingNoteReveal = range
        if !layout.showsNotes { layout = .split }
    }

    /// The editor took the pending reveal.
    public func consumeNoteReveal() {
        pendingNoteReveal = nil
    }

    /// Opens a notes page; its book follows when it lives in another document.
    public func openPage(_ id: PageID) async throws {
        guard let page = try await services.pages.page(id), page.trash == nil else {
            throw GlossError.notFound("that page")
        }
        if page.documentID != document?.id {
            try await openDocument(page.documentID)
        }
        self.page = page
        notesHistory.visit(id)
    }

    /// Opens a book at a passage (from a `gloss://passage/…` link or a marker click).
    public func openPassage(_ id: LinkTargetID) async throws {
        guard let target = try await services.links.linkTarget(id),
              let document = try await services.library.document(target.documentID), document.trash == nil else {
            throw GlossError.notFound("that passage")
        }
        try await openDocument(document.id, locator: target.passage.locator)
        pendingPassage = id
    }

    /// The notes pane follows the book when it changes.
    public func showRootPage() async throws {
        guard let document else { return }
        page = try await services.pages.rootPage(of: document.id)
    }

    // MARK: History

    public func goBackInReader() async throws {
        guard let previous = readerHistory.goBack() else { return }
        try await openDocument(previous.documentID, locator: previous.locator)
        readerHistory.replaceCurrent(with: previous)
    }

    public func goForwardInReader() async throws {
        guard let next = readerHistory.goForward() else { return }
        try await openDocument(next.documentID, locator: next.locator)
        readerHistory.replaceCurrent(with: next)
    }

    public func goBackInNotes() async throws {
        guard let previous = notesHistory.goBack() else { return }
        try await openPage(previous)
        notesHistory.replaceCurrent(with: previous)
    }

    public func goForwardInNotes() async throws {
        guard let next = notesHistory.goForward() else { return }
        try await openPage(next)
        notesHistory.replaceCurrent(with: next)
    }

    // MARK: Refresh (external changes, trash restores)

    /// Reloads the open document and page; drops them if they were trashed or purged.
    public func refresh() async {
        if let id = document?.id {
            document = try? await services.library.document(id)
        }
        if let id = page?.id {
            let reloaded = try? await services.pages.page(id)
            page = reloaded?.trash == nil ? reloaded : nil
        }
        if document?.trash != nil { document = nil; page = nil }
        // Drop history entries whose targets no longer exist.
        var liveReader: [ReaderFocus] = []
        for focus in readerHistory.backStack + (readerHistory.current.map { [$0] } ?? []) {
            if let document = try? await services.library.document(focus.documentID), document.trash == nil {
                liveReader.append(focus)
            }
        }
        readerHistory = NavigationHistory<ReaderFocus>()
        for focus in liveReader { readerHistory.visit(focus) }
        var liveNotes: [PageID] = []
        for id in notesHistory.backStack + (notesHistory.current.map { [$0] } ?? []) {
            if let page = try? await services.pages.page(id), page.trash == nil { liveNotes.append(id) }
        }
        notesHistory = NavigationHistory<PageID>()
        for id in liveNotes { notesHistory.visit(id) }
    }

    /// The search context, derived from what is open and how the window is split.
    public var searchContext: SearchContext {
        guard let document else { return .home }
        switch layout {
        case .readerOnly: return .reader(document.id)
        case .notesOnly: return .notes(document.id)
        case .split: return .split(document.id)
        }
    }

    private func persistLayout() async {
        guard persistLayoutSetting else { return }
        try? await services.settings.set(layout, for: WorkspaceSettings.layout)
    }

    /// Waits for any in-flight layout persistence (tests, and teardown before quit).
    public func flushLayoutPersistence() async {
        await persistTask?.value
    }

    /// Loads the persisted layout (composition root calls this once).
    public func loadPersistedLayout() async {
        guard persistLayoutSetting else { return }
        let stored = (try? await services.settings.value(WorkspaceSettings.layout)) ?? .split
        suppressLayoutPersist = true
        layout = stored
        suppressLayoutPersist = false
    }
}
