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
        // Only a successful read can show something is gone; a failed read keeps what's open.
        if let id = document?.id, case .success(let result) = await fetch(document: id) {
            document = result?.trash == nil ? result : nil
        }
        if let id = page?.id, case .success(let result) = await fetch(page: id) {
            page = result?.trash == nil ? result : nil
        }
        if document == nil {
            page = nil
            readerFocus = nil
            pendingPassage = nil
        }
        // Drop history entries whose targets are gone, keeping back and forward history.
        var deadBooks: Set<DocumentID> = []
        let books = Set(readerHistory.backStack.map(\.documentID) + readerHistory.forwardStack.map(\.documentID)
                        + (readerHistory.current.map { [$0.documentID] } ?? []))
        for id in books where await isGone(document: id) { deadBooks.insert(id) }
        if !deadBooks.isEmpty {
            readerHistory.removeAll { deadBooks.contains($0.documentID) }
            if let focus = readerFocus, deadBooks.contains(focus.documentID) { readerFocus = nil }
        }
        var deadPages: Set<PageID> = []
        let pages = Set(notesHistory.backStack + notesHistory.forwardStack + (notesHistory.current.map { [$0] } ?? []))
        for id in pages where await isGone(page: id) { deadPages.insert(id) }
        if !deadPages.isEmpty { notesHistory.removeAll { deadPages.contains($0) } }
    }

    /// Gone means a successful read found nothing, or found it in the trash.
    private func isGone(document id: DocumentID) async -> Bool {
        guard case .success(let result) = await fetch(document: id) else { return false }
        return result == nil || result?.trash != nil
    }

    private func isGone(page id: PageID) async -> Bool {
        guard case .success(let result) = await fetch(page: id) else { return false }
        return result == nil || result?.trash != nil
    }

    // `try?` would flatten "not found" and "read failed" into the same nil.
    private func fetch(document id: DocumentID) async -> Result<Document?, any Error> {
        do { return .success(try await services.library.document(id)) } catch { return .failure(error) }
    }

    private func fetch(page id: PageID) async -> Result<Page?, any Error> {
        do { return .success(try await services.pages.page(id)) } catch { return .failure(error) }
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

    /// Waits for any in-flight layout persistence (tests, and teardown before quit), including
    /// writes scheduled while waiting.
    public func flushLayoutPersistence() async {
        while let task = persistTask {
            await task.value
            if persistTask == task { break }
        }
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
