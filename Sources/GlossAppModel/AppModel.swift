import Foundation
import Observation
import GlossCore
import GlossExport
import GlossMarkdown
import GlossNotes
import GlossReaderBridge

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
    /// This window's library presentation state (the details sheet, the import panel).
    public let presentation = LibraryPresentationModel()
    /// Export and print (the composition root hands in the model over the cli's ExportService).
    public let export: ExportModel
    /// Moving things to the trash, with the undo toast (brief 39).
    public let deletion: DeletionModel
    public var linking: LinkingCoordinator { LinkingCoordinator(services: services, reader: reader) }
    public var changeMonitor: ExternalChangeMonitor?
    /// Why the last URL from outside couldn't be opened; the window shows it in a small alert.
    public private(set) var externalURLMessage: String?

    /// Observes settings saved in this process (the Settings window); other processes go
    /// through `handleExternalChanges`. `@ObservationIgnored`: the token is plumbing, not
    /// state; only ever touched on the main actor (init, the observer itself, deinit).
    @ObservationIgnored private var settingsToken: SettingsObserverToken

    /// The observer token, kept out of the main-actor-isolated stored properties so deinit
    /// (nonisolated) can remove it.
    struct SettingsObserverToken: @unchecked Sendable {
        let observer: (any NSObjectProtocol)?
    }
    /// Runs the reaction to a settings change; `flushSettingsChanges` waits for it.
    private var settingsTask: Task<Void, Never>?

    public init(services: GlossServices, export: ExportModel? = nil) {
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
        self.export = export ?? ExportModel(service: nil)
        self.deletion = DeletionModel(services: services)
        self.settingsToken = SettingsObserverToken(observer: nil)
        reader.highlightsDidChange = { [weak self] in await self?.refreshBookSidebar() }
        reader.openNote = { [weak self] page, range in
            try? await self?.workspace.openPage(page, revealing: range)
        }
        // A save that changed gloss links moves markers in the open book.
        notes.linksDidChange = { [weak self] in await self?.reader.refreshAnnotations() }
        // The Settings window saved (same process, so the change monitor never sees it):
        // reading settings go to the open book live, and retention re-dates the trash.
        // NotificationCenter delivers synchronously on the posting (main) thread (verified
        // against swift-corelibs-foundation), so the hop below is safe on both platforms.
        let observer = NotificationCenter.default.addObserver(forName: .glossSettingsChanged, object: nil, queue: nil) { [weak self] note in
            let settings = note.userInfo?[glossReaderSettingsKey] as? ReaderSettings
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settingsTask = Task { await self.applySettingsChange(settings) }
            }
        }
        self.settingsToken = SettingsObserverToken(observer: observer)
    }

    deinit {
        // The token is only ever touched on the main actor; the window is going away.
        let token = settingsToken
        if let observer = token.observer { NotificationCenter.default.removeObserver(observer) }
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
        // A retention change from the cli re-dates everything in the trash.
        if changes.contains(where: { $0.entity == ChangeEntity.trash || $0.entity == ChangeEntity.setting }) {
            await trash.reload()
        }
        await library.invalidate(ids: documentIDs.compactMap { DocumentID($0) })
        // The open page may have been trashed elsewhere; remember where it lived so the
        // notes pane can land somewhere alive once the refresh drops it.
        let vanishedPage: (parentID: PageID?, documentID: DocumentID)?
        if let page = workspace.page, pageIDs.contains(page.id.stringValue) {
            let fresh = try? await services.pages.page(page.id)
            vanishedPage = (parentID: fresh?.parentID ?? page.parentID, documentID: fresh?.documentID ?? page.documentID)
        } else {
            vanishedPage = nil
        }
        await workspace.refresh()
        if workspace.document != nil, workspace.page == nil, let vanishedPage {
            await landNotes(afterVanishing: vanishedPage)
        }
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

    // MARK: Moving to the trash (brief 39)

    /// Moves a book and everything in it to the trash, with the undo toast. Returns the entry
    /// when it went, nil when it couldn't (the toast says why).
    @discardableResult
    public func moveToTrash(_ document: Document) async -> TrashEntry? {
        guard let entry = await deletion.trash(kind: .document, id: document.id.stringValue) else { return nil }
        await reactToTrashing(documentIDs: [document.id])
        return entry
    }

    /// Moves a page and its subtree to the trash, with the undo toast. The open page lands on
    /// the trashed page's parent (or the book's root) when it was what went.
    @discardableResult
    public func moveToTrash(pageID: PageID) async -> TrashEntry? {
        let page: Page?
        do { page = try await services.pages.page(pageID) } catch { page = nil }
        guard let page else {
            deletion.reportFailure("couldn't find that page")
            return nil
        }
        guard let entry = await deletion.trash(kind: .page, id: page.id.stringValue) else { return nil }
        await reactToTrashing(documentIDs: [page.documentID],
                              vanished: (parentID: page.parentID, documentID: page.documentID))
        return entry
    }

    /// The toast's "undo", and Edit › Undo (⌘Z, D-019): restores the entry and whatever was
    /// trashed with it. Returns what came back, or nil when it was already gone.
    @discardableResult
    public func undoTrash(_ entry: TrashEntry) async -> [TrashEntry]? {
        guard let restored = await deletion.undo(entry) else { return nil }
        await reactToRestore(restored)
        return restored
    }

    /// Everything a window must do after its own user trashed something: the badge, the grid,
    /// the open book and page, the sidebar's page tree, the reader.
    private func reactToTrashing(documentIDs: [DocumentID], vanished: (parentID: PageID?, documentID: DocumentID)? = nil) async {
        await trash.reload()
        await library.invalidate(ids: documentIDs)
        await workspace.refresh()
        // A trashed open page lands somewhere sensible (see `landNotes`).
        if workspace.document != nil, workspace.page == nil {
            await landNotes(afterVanishing: vanished)
        }
        // The reader's book may have gone (its session must blank, not keep showing a ghost).
        if let open = reader.document, workspace.document?.id != open.id {
            await reader.close()
        }
        await showBookSidebar()
        search.contextChanged()
    }

    /// Where the notes pane lands when the open page went (trashed here or elsewhere): its
    /// parent if that's alive, else its book's main page, else the reader book's main page —
    /// the panes can show different books (D-102), and a trashed book's pages must never pull
    /// the notes back into it. One place, so every path lands the same way.
    public func landNotes(afterVanishing vanished: (parentID: PageID?, documentID: DocumentID)?) async {
        if let parentID = vanished?.parentID,
           let parent = try? await services.pages.page(parentID), parent.trash == nil,
           (try? await workspace.openPage(parent.id)) != nil {
            return
        }
        if let documentID = vanished?.documentID,
           let root = try? await services.pages.rootPage(of: documentID), root.trash == nil,
           (try? await workspace.openPage(root.id)) != nil {
            return
        }
        try? await workspace.showRootPage()  // the reader's book
    }

    /// Everything a window must do after an undo: the badge, the grid, the page tree, and —
    /// when what came back was the open book or page — going back there, like any undo.
    private func reactToRestore(_ restored: [TrashEntry]) async {
        await trash.reload()
        await library.invalidate(ids: restored.compactMap(\.documentID))
        await showBookSidebar()
        search.contextChanged()
        if workspace.document == nil, let bookEntry = restored.first(where: { $0.kind == .document }),
           let bookID = DocumentID(bookEntry.entityID) {
            try? await workspace.openDocument(bookID)
        }
        if let pageEntry = restored.first(where: { $0.kind == .page }),
           let pageID = PageID(pageEntry.entityID) {
            // D-102: opening a page moves only the notes pane, so undo returns to the restored
            // page even while the reader shows another book.
            try? await workspace.openPage(pageID)
        }
    }

    /// Reading settings changed in this process's Settings window: the open book takes them
    /// live (when its engine can reflow) and the trash re-dates itself.
    public func applySettingsChange(_ settings: ReaderSettings?) async {
        await trash.reload()
        if let settings {
            await reader.applyAppearanceIfSupported(AppearanceStyler().appearance(for: settings))
        }
    }

    /// Waits for the settings reaction (tests, and teardown before quit).
    public func flushSettingsChanges() async {
        while let task = settingsTask {
            await task.value
            if settingsTask == task { break }
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
        case .inTrash, .missing, .unreadable:
            break
        }
        return outcome
    }

    // MARK: The one doors for choices made outside a pane

    /// The one door every URL from outside goes through (brief 16: other apps, `gloss open`,
    /// Finder double-clicks). Classifies, routes, and — when it can't open something — leaves
    /// the reason in `externalURLMessage` for the window's alert.
    @discardableResult
    public func open(url: URL) async -> ExternalOpenOutcome {
        let outcome = await handle(url: url)
        externalURLMessage = UnopenableLinkCopy.message(for: outcome)
        return outcome
    }

    /// The alert's dismiss.
    public func dismissExternalURLMessage() {
        externalURLMessage = nil
    }

    private func handle(url: URL) async -> ExternalOpenOutcome {
        switch IncomingURLClassifier.classify(url, supportedExtensions: services.formats.supportedExtensions) {
        case .gloss(let link):
            switch await open(link) {
            case .routed(let route): return .routed(route)
            case .inTrash(let title): return .inTrash(title)
            case .missing: return .missing
            case .unreadable: return .unreadable
            }
        case .supportedFile(let file):
            let imported = await library.importFiles(at: [file])
            // A duplicate is not a failure: the existing copy is the destination.
            guard let document = imported.first ?? library.lastDuplicates.first else {
                return .refused("couldn't add \(file.lastPathComponent) — is it a book gloss can read?")
            }
            try? await workspace.openDocument(document.id)
            return .opened(document)
        case .other(let url):
            return .refused("gloss can't do anything with \(url.lastPathComponent)")
        }
    }

    /// Where a quick-switcher choice goes (brief 30).
    public func open(_ item: QuickSwitcherModel.Item) async {
        switch item.kind {
        case .document:
            try? await workspace.openDocument(item.documentID)
            workspace.layout = workspace.layout.showsReader ? workspace.layout : .split
        case .page:
            guard let pageID = item.pageID else { return }
            // A switcher pick is a jump from outside the panes: the page's book comes along (D-102).
            try? await workspace.openPage(pageID, bringingBook: true)
            workspace.layout = workspace.layout.showsNotes ? workspace.layout : .split
        }
    }

    /// Where a chosen search hit goes (brief 31): the page with the match revealed, the passage
    /// in the book, or the book itself.
    public func reveal(_ selection: SearchModel.Selection) async {
        switch selection {
        case .page(let pageID, _, let match):
            try? await workspace.openPage(pageID, revealing: match)
        case .bookText(let documentID, let locator, let matchText):
            if reader.document?.id == documentID {
                workspace.layout = workspace.layout.showsReader ? workspace.layout : .split
                await reader.reveal(searchHit: locator, text: matchText)
            } else {
                // Another book (or none): the reader shows it at the hit's locator (D-102: only
                // the reader moves — a search hit never drags the notes off their page). The
                // precise find-near-locator reveal only applies to the book already showing.
                try? await workspace.showBook(documentID, locator: locator)
                workspace.layout = workspace.layout.showsReader ? workspace.layout : .split
            }
        case .document(let documentID):
            try? await workspace.openDocument(documentID)
            workspace.layout = workspace.layout.showsReader ? workspace.layout : .split
        }
    }
}

/// A feed that never reports changes (when the store has no journal).
struct NoChanges: ChangeFeed {
    let origin = "none"
    func latestChangeSequence() async throws -> Int64 { 0 }
    func changes(after sequence: Int64, limit: Int) async throws -> [ChangeRecord] { [] }
    func trimChanges(before date: Date) async throws {}
}
