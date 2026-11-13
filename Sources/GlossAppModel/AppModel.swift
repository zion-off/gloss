import Foundation
import Observation
import GlossCore
import GlossMarkdown
import GlossNotes

/// One window's models over one set of services, plus the glue that reacts to external
/// changes. The Mac composition root builds this; views take the piece they need.
@MainActor @Observable public final class AppModel {
    public let services: GlossServices
    public let workspace: WorkspaceModel
    public let library: LibraryModel
    public let search: SearchModel
    public let trash: TrashModel
    public let switcher: QuickSwitcherModel
    public let router: URLRouter
    public let reader: ReaderController
    /// This window's notes editor (one per window; the services are shared).
    public let notes: NotesEditorModel
    /// The open book's highlights and pages in the source list.
    public let bookSidebar: BookSidebarModel
    public var linking: LinkingCoordinator { LinkingCoordinator(services: services, reader: reader) }
    public var changeMonitor: ExternalChangeMonitor?

    public init(services: GlossServices) {
        self.services = services
        self.workspace = WorkspaceModel(services: services)
        self.library = LibraryModel(services: services)
        self.search = SearchModel(services: services, contextProvider: { [workspace] in workspace.searchContext })
        self.trash = TrashModel(services: services)
        self.switcher = QuickSwitcherModel(services: services)
        self.router = URLRouter(links: services.links)
        self.reader = ReaderController(services: services)
        self.notes = NotesEditorModel(services: services)
        self.bookSidebar = BookSidebarModel(services: services)
        reader.highlightsDidChange = { [weak self] in await self?.refreshBookSidebar() }
        reader.openNote = { [weak self] page, range in
            try? await self?.workspace.openPage(page, revealing: range)
        }
        // A save that changed gloss links moves markers in the open book.
        notes.linksDidChange = { [weak self] in await self?.reader.refreshAnnotations() }
    }

    /// Wires the change monitor (call once at startup, after the views exist).
    public func startMonitoringChanges() async {
        guard changeMonitor == nil else { return }
        changeMonitor = await ExternalChangeMonitor(feed: services.store as? any ChangeFeed ?? NoChanges()) { [weak self] changes in
            await self?.handleExternalChanges(changes)
        }
    }

    /// Reloads what the changes touch.
    public func handleExternalChanges(_ changes: [ChangeRecord]) async {
        guard !changes.isEmpty else { return }
        let documentIDs = Set(changes.filter { $0.entity == ChangeEntity.document }.map(\.entityID))
        let pageIDs = Set(changes.filter { $0.entity == ChangeEntity.page }.map(\.entityID))
        if changes.contains(where: { $0.entity == ChangeEntity.trash }) {
            await trash.reload()
        }
        await library.invalidate(ids: documentIDs.compactMap { DocumentID($0) })
        await workspace.refresh()
        if let page = notes.page, pageIDs.contains(page.id.stringValue) {
            await notes.pageChangedExternally()
        }
        if !pageIDs.isEmpty || !documentIDs.isEmpty {
            search.contextChanged()
        }
        // The book in the reader may have gone (trashed or purged from the cli).
        if let open = reader.document, documentIDs.contains(open.id.stringValue) {
            do {
                let current = try await services.library.document(open.id)
                if current == nil || current?.trash != nil { await reader.close() }
            } catch {
                // A failed read proves nothing; keep the book open.
            }
        }
        let annotationEntities: Set<String> = [ChangeEntity.page, ChangeEntity.highlight, ChangeEntity.linkTarget]
        if changes.contains(where: { annotationEntities.contains($0.entity) }) {
            await reader.refreshAnnotations()
        }
        let sidebarEntities: Set<String> = [ChangeEntity.page, ChangeEntity.highlight, ChangeEntity.document]
        if changes.contains(where: { sidebarEntities.contains($0.entity) }) {
            await showBookSidebar()
        }
    }

    // MARK: The source list

    /// The open book's table of contents, as the sidebar nests it.
    public var contents: [ContentsNode] { ContentsNode.nodes(from: reader.toc) }

    /// The books the source list's book section shows: the reader's and the notes pane's.
    public var bookSidebarSubjects: BookSidebarSubjects {
        BookSidebarSubjects(reader: workspace.document?.id, notes: workspace.page?.documentID)
    }

    /// Loads the sidebar's section for the open book (the window calls this whenever
    /// `bookSidebarSubjects` changes).
    public func showBookSidebar() async {
        await bookSidebar.load(bookSidebarSubjects)
        dropDanglingSelection()
    }

    func refreshBookSidebar() async {
        await bookSidebar.refresh()
        dropDanglingSelection()
    }

    /// A selected highlight that is gone leaves the book selected, not a ghost row.
    private func dropDanglingSelection() {
        if case .highlight(let id) = workspace.sidebar, !bookSidebar.highlights.contains(where: { $0.id == id }) {
            workspace.sidebar = workspace.document == nil ? .library(nil) : .book
        }
    }

    /// A click in the source list: shows a shelf or the trash, or goes somewhere in the open book
    /// (revealing the pane it lands in when the layout hides it).
    public func select(_ selection: SidebarSelection) async {
        switch selection {
        case .library(let shelf):
            workspace.sidebar = selection
            if library.shelf != shelf { library.shelf = shelf }
        case .trash:
            workspace.sidebar = selection
            await trash.reload()
        case .book:
            guard workspace.document != nil else { return }
            workspace.sidebar = selection
        case .contents(let id):
            guard workspace.document != nil, let node = ContentsNode.find(id, in: contents) else { return }
            workspace.sidebar = selection
            if !workspace.layout.showsReader { workspace.layout = .split }
            await reader.go(to: node.target)
        case .highlight(let id):
            guard let highlight = bookSidebar.highlights.first(where: { $0.id == id }) else { return }
            workspace.sidebar = selection
            if !workspace.layout.showsReader { workspace.layout = .split }
            await reader.go(to: highlight.passage.locator, flash: true)
        case .page(let id):
            // The outline is the notes pane's book: picking a page moves only the notes (D-102).
            do { try await workspace.openPage(id) } catch { return }
            if !workspace.layout.showsNotes { workspace.layout = .split }
        }
        search.contextChanged()
    }

    /// Opens the reader where the workspace points (the window calls this whenever
    /// `workspace.readerFocus` changes): the book at its passage, or at the saved position.
    public func showReaderFocus() async {
        guard let focus = workspace.readerFocus, let document = workspace.document, document.id == focus.documentID else { return }
        await reader.open(document, at: focus.locator)
    }

    // MARK: Linking across the panes

    /// The editor's selection, as the link gesture sees it (nil without a page).
    public var notesSelection: NotesSelection? {
        notes.page.map { NotesSelection(pageID: $0.id, range: notes.selection) }
    }

    /// Whether "link to passage" (⌘K) can run, with the hint to show when it can't.
    public var linkAvailability: LinkGestureAvailability {
        linking.availability(notes: notesSelection, document: notes.page == nil ? nil : notes.document)
    }

    /// Links the editor's selected words to the book's selected passage. The editor applies the
    /// returned edit (one undo step); its autosave then makes the marker appear.
    public func linkSelectionToPassage() async throws -> EditResult {
        try await linking.linkToPassage(notes: notesSelection, document: notes.document)
    }

    /// "add to notes": the book's selection as a quote line at the editor's caret, as an edit
    /// for the editor to apply. Nil when it changes nothing.
    public func quoteSelectionIntoNotes() async throws -> EditResult? {
        guard notes.page != nil else { throw GlossError.notAllowed("open a notes page first") }
        let body = notes.text
        let (insertion, _) = try await linking.quoteInsertion(into: body, caret: notes.selection.upperBound)
        guard let edit = TextDiff.minimalEdit(from: body, to: insertion.body) else { return nil }
        return EditResult(edits: [edit], selection: insertion.caret..<insertion.caret)
    }

    /// "add to notes" from the reader's selection popover. With a page in the editor and the
    /// notes pane showing, returns the edit for the editor to apply (undoable, at the caret);
    /// otherwise writes the quote line at the end of the book's open notes page and returns nil.
    public func addReaderSelectionToNotes() async throws -> EditResult? {
        guard let book = reader.selection else { throw GlossError.notAllowed("select a passage in the book first") }
        if workspace.layout.showsNotes, let page = notes.page, page.documentID == book.documentID {
            return try await quoteSelectionIntoNotes()
        }
        let page: PageID
        if let shown = workspace.page, shown.documentID == book.documentID {
            page = shown.id
        } else if let root = try await services.pages.rootPage(of: book.documentID) {
            page = root.id
        } else {
            throw GlossError.notFound("this book's notes")
        }
        try await linking.addSelectionToNotes(page: page)
        await notes.pageChangedExternally()
        return nil
    }

    /// Follows a `gloss://` link clicked in the notes. It moves the pane it points into (D-102): a
    /// passage or a book swaps the reader, a page the notes. The other pane stays put, so a link
    /// into another book keeps your notes beside it (brief 15).
    @discardableResult
    public func follow(_ link: GlossLink) async -> RouteOutcome {
        await go(to: link, bringingOtherPane: false)
    }

    /// Opens a `gloss://` link from outside the panes (another app, `gloss open`, open quickly):
    /// the place it names, with its book or its notes alongside.
    @discardableResult
    public func open(_ link: GlossLink) async -> RouteOutcome {
        await go(to: link, bringingOtherPane: true)
    }

    private func go(to link: GlossLink, bringingOtherPane bring: Bool) async -> RouteOutcome {
        let outcome = await router.route(link)
        switch outcome {
        case .routed(.document(let id)):
            if bring { try? await workspace.openDocument(id) } else { try? await workspace.showBook(id) }
            if !workspace.layout.showsReader { workspace.layout = .split }
        case .routed(.page(let pageID, _)):
            try? await workspace.openPage(pageID, bringingBook: bring)
            if !workspace.layout.showsNotes { workspace.layout = .split }
        case .routed(.passage(let targetID, _)):
            try? await workspace.openPassage(targetID, bringingNotes: bring)
            if !workspace.layout.showsReader { workspace.layout = .split }
        case .inTrash, .missing:
            break
        }
        return outcome
    }
}

/// A feed that never reports changes (when the store has no journal).
struct NoChanges: ChangeFeed {
    let origin = "none"
    func latestChangeSequence() async throws -> Int64 { 0 }
    func changes(after sequence: Int64, limit: Int) async throws -> [ChangeRecord] { [] }
    func trimChanges(before date: Date) async throws {}
}
