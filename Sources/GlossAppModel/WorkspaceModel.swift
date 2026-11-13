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

    /// The source list's selection (D-101). Opening a book or a page selects it; `AppModel.select`
    /// handles clicks.
    public internal(set) var sidebar: SidebarSelection = .library(nil)

    /// What the detail column shows: the grid, the trash, or the open book.
    public var detail: SidebarDetail {
        switch sidebar {
        case .library(let shelf): .library(shelf)
        case .trash: .trash
        case .book, .contents, .highlight, .page: document == nil ? .library(nil) : .book
        }
    }

    /// Books this window opened (markOpened re-dates them): AppModel tells the app's other
    /// windows, whose recent shelves would otherwise wait for a foreign process's write.
    public var onOpened: (@MainActor (DocumentID) -> Void)?

    private let services: GlossServices
    private let persistLayoutSetting: Bool

    public init(services: GlossServices, layout: SplitLayout = .split, persistLayoutSetting: Bool = true) {
        self.services = services
        self.layout = layout
        self.persistLayoutSetting = persistLayoutSetting
    }

    // MARK: Opening (D-102: each pane moves on its own)

    /// Chooses a book (the library, open quickly): the reader shows it, at `locator` or where it
    /// was left, and the notes show its main page unless they already show one of its pages.
    public func openDocument(_ id: DocumentID, locator: Locator? = nil) async throws {
        let switched = self.document?.id != id
        try await showInReader(id, locator: locator)
        if page?.documentID != id { try await showMainPage(of: id) }
        // Opening a book shows it; a selection in the previous book's section means nothing here.
        if switched || !sidebar.showsBook { sidebar = page.map { .page($0.id) } ?? .book }
    }

    /// Shows a book in the reader pane alone (a `gloss://book/…` link in the notes, reader
    /// back/forward). The notes stay on their page, even in another book; they only get the
    /// book's main page when they show nothing.
    public func showBook(_ id: DocumentID, locator: Locator? = nil) async throws {
        let switched = document?.id != id
        try await showInReader(id, locator: locator)
        if page == nil { try await showMainPage(of: id) }
        guard switched else { return }
        // History moves the reader behind whatever the detail column shows: while the grid or
        // the trash is front, it never hijacks the window (review 7; D-102's "each pane moves
        // alone" reads both ways). A contents entry or highlight of the previous book means
        // nothing now; a notes page still does (the notes didn't move).
        guard sidebar.showsBook else { return }
        switch sidebar {
        case .contents, .highlight: sidebar = page.map { .page($0.id) } ?? .book
        default: break
        }
    }

    /// Opens a notes page at a range (a marker click), revealing the notes pane if hidden. The
    /// reader stays on its book, which may be another one (a cross-book link's marker).
    public func openPage(_ id: PageID, revealing range: Range<Int>?) async throws {
        try await openPage(id)
        pendingNoteReveal = range
        if !layout.showsNotes { layout = .split }
    }

    /// The editor took the pending reveal.
    public func consumeNoteReveal() {
        pendingNoteReveal = nil
    }

    /// Opens a notes page in the notes pane (a page link, subpage row, breadcrumb, the source
    /// list's outline, notes back/forward). The reader stays where it is, even on another book,
    /// unless `bringingBook` (a jump from outside the panes: open quickly, a `gloss://` URL from
    /// another app) or no book is open at all. A reveal meant for the page shown before is
    /// dropped (only `openPage(_:revealing:)` sets one).
    public func openPage(_ id: PageID, bringingBook: Bool = false) async throws {
        pendingNoteReveal = nil
        guard let page = try await services.pages.page(id), page.trash == nil else {
            throw GlossError.notFound("that page")
        }
        if document == nil || (bringingBook && page.documentID != document?.id) {
            try await showInReader(page.documentID, locator: nil)
        }
        self.page = page
        notesHistory.visit(id)
        sidebar = .page(id)
    }

    /// Opens a book at a passage in the reader pane (a passage link in the notes). The notes stay
    /// on their page, even in another book (that is how a cross-book link is followed, brief 15),
    /// unless `bringingNotes` (a jump from outside the panes) or they show nothing.
    public func openPassage(_ id: LinkTargetID, bringingNotes: Bool = false) async throws {
        guard let target = try await services.links.linkTarget(id),
              let document = try await services.library.document(target.documentID), document.trash == nil else {
            throw GlossError.notFound("that passage")
        }
        if bringingNotes {
            try await openDocument(document.id, locator: target.passage.locator)
        } else {
            try await showBook(document.id, locator: target.passage.locator)
        }
        pendingPassage = id
    }

    /// The notes pane follows the book when it changes.
    public func showRootPage() async throws {
        guard let document else { return }
        page = try await services.pages.rootPage(of: document.id)
    }

    /// The reader pane alone: shows a book and records it in the reader's history (a no-op for
    /// the entry back/forward just moved to).
    private func showInReader(_ id: DocumentID, locator: Locator?) async throws {
        guard let document = try await services.library.document(id), document.trash == nil else {
            throw GlossError.notFound("that book")
        }
        self.document = document
        try await services.library.markOpened(id)
        readerHistory.visit(ReaderFocus(documentID: id, locator: locator))
        readerFocus = readerHistory.current
        pendingPassage = nil
    }

    /// The notes pane alone: shows a book's main page and records it in the notes' history.
    private func showMainPage(of id: DocumentID) async throws {
        page = try await services.pages.rootPage(of: id)
        if let page { notesHistory.visit(page.id) }
    }

    // MARK: History (each pane its own, brief 15)

    public func goBackInReader() async throws {
        guard let previous = readerHistory.goBack() else { return }
        try await showBook(previous.documentID, locator: previous.locator)
        readerHistory.replaceCurrent(with: previous)
    }

    public func goForwardInReader() async throws {
        guard let next = readerHistory.goForward() else { return }
        try await showBook(next.documentID, locator: next.locator)
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
            if sidebar.showsBook { sidebar = .library(nil) }
        } else if case .page(let id) = sidebar, page?.id != id {
            sidebar = .book  // the selected page went
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
        guard let document, sidebar.showsBook else { return .home }
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
