import AppKit
import SwiftUI
import GlossAppModel
import GlossCore
import GlossEditor
import GlossNotes
import GlossReaderBridge
import GlossReaderKit

/// One window: the source list in the sidebar; the library, the trash or the open book in
/// the detail column. Each window has its own models (AppModel is one window's state) over the
/// shared services, which the composition root (GlossMac) hands in with the reading engines.
public struct MainWindow: View {
    @Environment(\.undoManager) private var undoManager
    /// The window's light or dark mode: a book in auto-night follows it.
    @Environment(\.colorScheme) private var colorScheme
    private let engines: ReadingEngineRegistry
    private let prepare: @MainActor () async -> Void
    @State private var app: AppModel
    @State private var started = false
    @State private var reveal: NotesReveal?
    @State private var unsavedFailure: String?
    @State private var commands: WindowCommands
    @State private var exportActions: ExportActions
    /// The window's "back up library…" flow (File menu reaches it through a focused value).
    @State private var backup: BackupCommands
    /// The reader's engine session lives with the window, so hiding the reader keeps the book.
    @State private var readerHost = ReaderSessionHost()

    /// - Parameter prepare: once-per-launch setup to await before the first book shows
    ///   (reading settings, routine upkeep); every window calls it, the root runs it once.
    /// - Parameter export: the root's export model; nil leaves the File menu's export and
    ///   print items disabled rather than broken (tests and slices that don't export).
    /// - Parameter backupActivity: shared with automatic backup, which waits for a manual one.
    public init(services: GlossServices, engines: ReadingEngineRegistry, export: ExportModel? = nil,
                backupActivity: BackupActivity = BackupActivity(),
                prepare: @escaping @MainActor () async -> Void) {
        self.engines = engines
        self.prepare = prepare
        let app = AppModel(services: services, export: export)
        let commands = WindowCommands()
        commands.bind(app)
        let exportActions = ExportActions()
        exportActions.bind(app)
        _app = State(initialValue: app)
        _commands = State(initialValue: commands)
        _exportActions = State(initialValue: exportActions)
        _backup = State(initialValue: BackupCommands(services: services, activity: backupActivity))
    }

    /// Docked (the content makes room) or undocked (it floats in over the content from the
    /// window's leading edge): one choice for every place and every window, remembered.
    @AppStorage("sidebar.docked") private var sidebarDocked = true
    /// The docked sidebar's width as last dragged; the floating one matches it.
    @AppStorage("sidebar.width") private var sidebarWidth = 220.0
    @State private var docking = SidebarDocking(docked: true)
    /// Bumped whenever the source list comes into view (the sidebar docking or floating in, the
    /// search results leaving it), so it can bring the chapter being read into view.
    @State private var sidebarRevealToken = 0

    // The body is split into a few properties on purpose: as one modifier chain it took the
    // type checker about 26 s (Swift 6.2, -warn-long-function-bodies), most of a clean build.
    public var body: some View {
        windowChrome
        .task { await run() }
        .task(id: app.workspace.readerFocusRequest) { await app.showReaderFocus() }
        .task(id: app.bookSidebarSubjects) {
            await app.showBookSidebar()
            // The search follows the context: a session keeps its book (switching to another
            // one any other way ends it), and without a session the scope adopts the default
            // for where the user now is.
            await app.searchFollowsContext()
        }
        .task(id: app.workspace.pendingNoteReveal) {
            if let range = app.workspace.pendingNoteReveal, let page = app.workspace.page {
                reveal = NotesReveal(pageID: page.id, range: range, focusesText: app.workspace.pendingNoteRevealFocuses)
                app.workspace.consumeNoteReveal()
            }
        }
        .alert("this page has unsaved changes", isPresented: Binding(get: { unsavedFailure != nil },
                                                                        set: { if !$0 { unsavedFailure = nil } })) {
            // Cancel role so Escape means "keep editing" too: the natural way out of a
            // refuse-to-switch alert.
            Button("keep editing", role: .cancel) { Task { await keepEditing() } }
            Button("discard and switch", role: .destructive) { Task { await switchDiscarding() } }
        } message: {
            Text(verbatim: "the last save failed (\(unsavedFailure ?? "something went wrong")). switching pages would drop what you typed.")
        }
        .onDisappear {
            // The window is going away: nothing will fire the debounced save or the position
            // write anymore. Flush both so up to half a second of typing isn't lost,
            // and the layout and sort choices too — their persist chains hold the window weakly,
            // so the last ⌥⌘1/2/3 or sort click would otherwise die with it.
            Task { await app.notes.flushSave() }
            Task { await app.reader.flushPosition() }
            Task { await app.workspace.flushLayoutPersistence() }
            Task { await app.library.flushSortPersistence() }
        }
    }


    /// The toolbar, the search, the window's sheets and alerts and its focused values.
    private var windowChrome: some View {
        windowContent
        // The system's own inline title, after back/forward (the navigation placement goes "ahead
        // of the inline title"). It is also what splits the toolbar into a leading and a trailing
        // part: removing it (`toolbar(removing: .title)`) left nothing
        // between them, and every item packed in after the chevrons.
        .navigationTitle(title)
        .toolbar { toolbar }
        .glossSearch(model: app.search)
        // Escape leaves the search from anywhere in the window, not only from the field.
        .onExitCommand { if app.search.showsResults { Task { await app.endSearch() } } }
        // Results arriving (typing, a scope change) re-derive what the session highlights; the
        // engines' searches are generation-guarded, so a query mid-typing cancels the last one.
        .onChange(of: app.search.results) { _, _ in Task { await app.applySearchHighlights() } }
        .libraryFeatures(app: app)  // the drop zone, ⇧⌘A, the import alert, the details sheet, the sort menu
        .quickSwitcher(app: app, isPresented: Binding(get: { commands.showsSwitcher },
                                                       set: { commands.showsSwitcher = $0 }))
        .externalURLHandling(app: app, ready: started)
        .exportFailureAlert(app: app)
        .focusedSceneValue(\.windowCommands, commands)
        .focusedSceneValue(\.exportActions, exportActions)
        .focusedSceneValue(\.backupCommands, backup)
        .backupResultAlert(backup)
        .overlay(alignment: .bottom) { TrashToastOverlay(app: app) }
    }

    /// gloss's own sidebar beside the detail, or floating over it while undocked. Not a split
    /// view: a split view's collapsed sidebar has reveals of its own (the full-screen edge, macOS
    /// 26's peek) that fought the floating sidebar for the window's edge, with no public way to
    /// turn them off. The docked sidebar stays mounted while undocked, parked past the window's
    /// edge, so docking slides it in rather than building the source list on the slide's first
    /// frame.
    private var windowContent: some View {
        ZStack(alignment: .leading) {
            detailColumn
                // A click on empty space takes focus from the search field (and any other field):
                // a plain background view never asks for it, so it stayed in the field.
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { NSApp.keyWindow?.makeFirstResponder(nil) })
                // Undocked, the sidebar floats over the content instead of moving it.
                .overlay(alignment: .leading) {
                    if !docking.isDocked {
                        FloatingSidebar(app: app, docking: docking, revealToken: sidebarRevealToken,
                                        width: sidebarWidth, hover: hover)
                    }
                }
                .padding(.leading, docking.isDocked ? sidebarWidth + 1 : 0)
            DockedSidebar(width: $sidebarWidth) {
                SidebarContent(app: app, revealToken: sidebarRevealToken)
            }
            .offset(x: docking.isDocked ? 0 : -(sidebarWidth + 1))
            .disabled(!docking.isDocked)
            .accessibilityHidden(!docking.isDocked)
        }
        .clipped()
        .onChange(of: colorScheme, initial: true) { _, scheme in
            Task { await app.systemAppearanceChanged(dark: scheme == .dark) }
        }
        // The remembered choice, at launch and when another window changes it.
        .onChange(of: sidebarDocked, initial: true) { old, new in
            commands.sidebarDocked = new
            commands.toggleSidebarDocking = { sidebarDocked.toggle() }
            dock(new, animated: old != new)
        }
        // The floating panel is kept between floats, so it brings the chapter being read into view
        // each time it comes in, as the docked one does when it docks.
        .onChange(of: docking.isFloating) { _, floating in if floating { sidebarRevealToken += 1 } }
        // Undocked, search results inside a book float the sidebar in and hold it until they go;
        // the results themselves appear without any transition (the owner removed that one as
        // too slow).
        .onChange(of: app.search.showsResultsInSidebar) { _, showing in
            withAnimation(Self.floatAnimation) { docking.holdsForSearch = showing }
            if !showing { sidebarRevealToken += 1 }  // the source list is back in view
        }
    }

    @ViewBuilder private var detailColumn: some View {
            if started {
                if app.search.showsResultsInMainPane {
                    // On the library, searching replaces the detail column, Mail-style; choosing
                    // a hit jumps there and the session follows into the book (its results take
                    // the sidebar). Inside a book the results take the sidebar instead, and the
                    // main pane keeps the book.
                    SearchResults(app: app, placement: .mainPane)
                } else {
                    switch app.workspace.detail {
                    case .library:
                        LibraryGrid(library: app.library, presentation: app.presentation, open: open,
                                   moveToTrash: moveToTrash)
                    case .trash:
                        TrashView(trash: app.trash, presentation: app.presentation)
                    case .book:
                        book
                    }
                }
            } else {
                ProgressView()
            }
        
    }

    /// The book: the reader is an inset card with a soft shadow, the notes a flat panel beside it
    /// with one draggable divider. Both are laid out inside the content area, not as an inspector or
    /// an NSSplitView, so the toolbar stays one bar across the window and the divider starts below
    /// it. The reader's session lives in `readerHost`, so showing the library (or another layout)
    /// and coming back keeps the book where it was.
    @ViewBuilder private var book: some View {
        ReaderNotesLayout(layout: app.workspace.layout) { readerCard } notes: { notesPane }
            // One big sheet of paper: the book is laid on it, inset, and the notes are written on it.
            .background(Color(nsColor: .textBackgroundColor))
    }

    private var readerCard: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ReaderPane(reader: app.reader, engines: engines, host: readerHost,
                          addToNotes: { await commands.addToNotes() })
            .clipShape(shape)
            .background { shape.fill(.background).shadow(color: .black.opacity(0.28), radius: 7, y: 2) }
            // One margin all round; beside the notes the notes' own margin is the gap, so
            // the card's edge is exactly one margin from the notes text.
            .padding(EdgeInsets(top: SheetMetrics.margin, leading: SheetMetrics.margin, bottom: SheetMetrics.margin,
                                trailing: app.workspace.layout == .split ? 0 : SheetMetrics.margin))
            .frame(minWidth: 320)
    }

    private var notesPane: some View {
        NotesPane(app: app, reveal: reveal, unsavedFailure: $unsavedFailure, commands: commands)
            .notesExportMenu(actions: exportActions)
    }

    /// The window's title follows the detail column: the shelf, the trash, or the book.
    private var title: String {
        switch app.workspace.detail {
        case .library(let shelf?): shelf.rawValue
        case .library(nil): "library"
        case .trash: "trash"
        case .book: app.workspace.document?.title ?? "gloss"
        }
    }

    /// Back and forward, then the title, on the leading edge (Finder, Safari); the layout switch
    /// right beside the search field on the trailing side. Back/forward is its own item, a
    /// `ControlGroup` in the navigation style, so the system draws Finder's grouped pair (one
    /// capsule, system chevrons, hover and disabled states); the system's inline title follows it.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { sidebarButton }
        ToolbarItem(placement: .navigation) { backForward }
        // No `DefaultToolbarItem(kind: .title)`: on macOS 26 it drew an empty glass capsule of its
        // own while `navigationTitle` drew the title beside it. The system title already
        // follows the navigation items.
        // The trailing cluster, flush right like Finder's, after the system title: `.automatic`
        // items, a flexible spacer first on macOS 26, search last.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .automatic)
        }
        // An import's progress, like Safari's downloads or Mail's activity, wherever the window is
        // (a Finder or gloss:// import can run while a book is open).
        if app.library.importing {
            ToolbarItem(placement: .automatic) { ImportActivity(library: app.library) }
        }
        // The sort menu only on the library, right before the search.
        if case .library = app.workspace.detail {
            ToolbarItem(placement: .automatic) { LibrarySortMenu(app: app) }
        }
        // Only while the book is on screen: on the library or the trash there is no reader to lay out.
        if case .book = app.workspace.detail {
            ToolbarItem(placement: .automatic) {
                Picker("layout", selection: Binding(get: { commands.layout }, set: { commands.layout = $0 })) {
                    Label("reader and notes", systemImage: "rectangle.split.2x1").tag(SplitLayout.split)
                    Label("reader only", systemImage: "book").tag(SplitLayout.readerOnly)
                    Label("notes only", systemImage: "note.text").tag(SplitLayout.notesOnly)
                }
                .pickerStyle(.segmented)
                .help("layout (⌥⌘1, ⌥⌘2, ⌥⌘3)")
            }
        }
        if case .trash = app.workspace.detail {
            ToolbarItem(placement: .automatic) {
                Button("empty trash", role: .destructive) { app.presentation.confirmsEmptyTrash = true }
                    .disabled(app.trash.items.isEmpty)
            }
        }
        // Search last, at the right edge. Every trailing item is declared here, in this order, so
        // nothing a detail view contributes can land after it. On macOS 26 it rests as a
        // magnifying glass and the field takes its place while the search is open (`glossSearch`).
        if #available(macOS 26.0, *) {
            if app.search.showsResults {
                DefaultToolbarItem(kind: .search, placement: .automatic)
            } else {
                ToolbarItem(placement: .automatic) { SearchToolbarButton(model: app.search) }
            }
        }
    }

    private var backForward: some View {
        ControlGroup {
            Button { commands.goBack() } label: { Label("back", systemImage: "chevron.left") }
                .disabled(!commands.canGoBack)
                .help("back (⌘[)")
            Button { commands.goForward() } label: { Label("forward", systemImage: "chevron.right") }
                .disabled(!commands.canGoForward)
                .help("forward (⌘])")
        }
        .controlGroupStyle(.navigation)
    }

    // MARK: Sidebar

    /// The floating sidebar's slide: quick, since it answers the pointer.
    private static let floatAnimation = Animation.smooth(duration: 0.2)
    /// Docking and undocking: the docked sidebar slides and the content makes room, as a split
    /// view's sidebar does.
    private static let dockAnimation = Animation.smooth(duration: 0.28)

    /// Docks or undocks the sidebar, like View › show sidebar (⌃⌘S). Hovering it does nothing:
    /// the window's leading edge is what floats the undocked sidebar in.
    private var sidebarButton: some View {
        Button { sidebarDocked.toggle() } label: {
            Label(docking.isDocked ? "hide sidebar" : "show sidebar", systemImage: "sidebar.left")
        }
        .help(docking.isDocked ? "hide sidebar (⌃⌘S)" : "show sidebar (⌃⌘S)")
    }

    /// Docks or undocks to match `docked`. The docked sidebar slides, except when a floating one is
    /// docked: the docked one takes its place at once rather than sliding in from nothing.
    private func dock(_ docked: Bool, animated: Bool) {
        let wasFloating = docking.isFloating
        if animated, !wasFloating {
            withAnimation(Self.dockAnimation) { docking.setDocked(docked) }
        } else {
            docking.setDocked(docked)
        }
        if docked { sidebarRevealToken += 1 }  // the docked list is in view again
    }

    private func hover(_ zone: SidebarDocking.Zone, _ inside: Bool) {
        guard !inside else {
            withAnimation(Self.floatAnimation) { docking.enter(zone) }
            return
        }
        guard let linger = docking.leave(zone) else { return }
        Task {
            try? await Task.sleep(for: SidebarDocking.linger)
            withAnimation(Self.floatAnimation) { docking.settle(linger) }
        }
    }


    /// Stays on the page the editor still shows (its unsaved text intact): the workspace goes
    /// back there, and reloading the page already shown keeps the editor's text.
    private func keepEditing() async {
        if let page = app.notes.page { try? await app.workspace.openPage(page.id) }
    }

    private func switchDiscarding() async {
        guard let page = app.workspace.page else { return }
        try? await app.notes.load(page, discardingUnsaved: true)
    }

    /// brief 39's move-to-trash (with its undo toast) lands with the trash slice; the lead wires
    /// this closure at merge. The grid takes it as a parameter so that slice owns the behaviour.
    private func moveToTrash(document: Document) {
        app.trashBook(document, undoManager: undoManager)
    }

    /// Starts the window, then polls for changes from the cli and other windows once a second
    /// until the window closes (the task is cancelled with it).
    private func run() async {
        await prepare()
        await app.workspace.loadPersistedLayout()
        app.reader.openExternal = { url in _ = NSWorkspace.shared.open(url) }
        await app.library.loadPersistedSort()  // one sort for every window, before the first grid
        await app.library.reload()
        await app.trash.reload()  // the source list's badge
        await app.loadSettings()
        await app.startMonitoringChanges()
        started = true
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            await app.changeMonitor?.poll()
            await app.library.syncSort()  // a sort changed in another window lands here within a second
        }
    }

    private func open(_ id: DocumentID) async {
        // A book that just went (trashed from the cli) stays unopened; the next poll drops it.
        try? await app.workspace.openDocument(id)
    }
}

/// The sheet's one margin, shared with the notes editor's text inset.
enum SheetMetrics {
    static let margin = NotesEditorMetrics.margin
}

/// The notes half of the window: the editor under its page's header, and a note when a save failed.
struct NotesPane: View {
    let app: AppModel
    let reveal: NotesReveal?
    @Binding var unsavedFailure: String?
    /// The window's commands: ⌘K, add to notes and history reach the editor through these.
    let commands: WindowCommands
    /// Why the last link clicked in the notes went nowhere (shown in an alert).
    @State private var linkProblem: RouteProblem?

    var body: some View {
        NotesEditor(model: app.notes, reveal: reveal,
                    onOpenGlossLink: { link in linkProblem = await app.follow(link).problem },
                    onOpenWebLink: { url in _ = NSWorkspace.shared.open(url) },
                    onOpenPage: { id in Task { try? await app.workspace.openPage(id) } },
                    actions: { actions in
                        commands.editor = actions
                        actions.onFocusChange = { focused in commands.notesFocused = focused }
                    }) {
            NotesPageHeader(app: app, commands: commands)
        }
        .overlay(alignment: .bottom) {
            if let message = failedMessage {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .task(id: app.workspace.page?.id) { await loadPage() }
        .alert(Text(verbatim: linkProblem?.title ?? ""),
               isPresented: Binding(get: { linkProblem != nil }, set: { if !$0 { linkProblem = nil } })) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(verbatim: linkProblem?.detail ?? "")
        }
    }

    private var failedMessage: String? {
        if case .failed = app.notes.saveState { return "couldn't save — your words are still here" }
        return nil
    }

    private func loadPage() async {
        guard let page = app.workspace.page else { return }
        do {
            try await app.notes.load(page)
        } catch let NotesEditorModel.EditorError.unsavedChanges(reason) {
            unsavedFailure = reason
        } catch {}
    }
}

/// The page's breadcrumbs and title, above its body. The editor hosts it in its scrolled area, so
/// it scrolls away with the text; it keeps its own state (the title being typed and its focus),
/// because it lives in a hosting view of its own.
private struct NotesPageHeader: View {
    let app: AppModel
    let commands: WindowCommands
    /// The title field: what is typed, the page it belongs to and what it started as (a commit
    /// writes only a real change, and to the page it was typed for, not the one shown by then).
    @State private var titleDraft = ""
    @State private var titleOwner: PageID?
    @State private var titleBaseline = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            titleField
        }
        .onChange(of: app.notes.page?.id, initial: true) { _, _ in
            commitTitle()  // for the page that was showing, before the field changes hands
            resetTitle()
            focusTitleIfNew()
        }
        .onChange(of: app.notes.page?.title) { _, _ in
            if !titleFocused { resetTitle() }  // renamed elsewhere (another window, the cli)
        }
    }

    /// The way up: the pages above this one. The page itself is the title field's job.
    @ViewBuilder private var breadcrumbs: some View {
        let ancestors = app.notes.breadcrumbs.dropLast()
        if !ancestors.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(ancestors.enumerated()), id: \.offset) { index, page in
                    if index > 0 { Text(verbatim: "›").foregroundStyle(.tertiary) }
                    Button(page.title.isEmpty ? PageService.untitled : page.title) {
                        Task { try? await app.workspace.openPage(page.id) }
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                }
                Text(verbatim: "›").foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SheetMetrics.margin)
            .padding(.top, SheetMetrics.margin)
        }
    }

    /// The page's own title, above its body. It wraps onto as many lines as it needs,
    /// like a Notes or Notion title; Return saves it and moves on into the body, leaving the field
    /// saves it too. A title is one line of text: Return never becomes a newline, and pasted line
    /// breaks become spaces.
    private var titleField: some View {
        TextField("untitled", text: titleText, axis: .vertical)
            .lineLimit(1...)
            .textFieldStyle(.plain)
            .font(.system(size: CGFloat(app.notes.textSize) * NotesEditorMetrics.titleScale, weight: .bold))
            .focused($titleFocused)
            .onSubmit { submitTitle() }
            .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
            // The body's glyphs start one margin in: the title and breadcrumbs share that edge.
            .padding(.horizontal, SheetMetrics.margin)
            .padding(.top, app.notes.breadcrumbs.count > 1 ? 4 : SheetMetrics.margin)
    }

    /// The draft, minus line breaks: a lone one typed into the field is Return (save and move on);
    /// any others (a paste) turn into spaces.
    private var titleText: Binding<String> {
        Binding(get: { titleDraft }, set: { new in
            guard new.contains(where: \.isNewline) else { titleDraft = new; return }
            if new.filter({ !$0.isNewline }) == titleDraft, new.filter(\.isNewline).count == 1 {
                submitTitle()
            } else {
                titleDraft = new.split(whereSeparator: \.isNewline).joined(separator: " ")
            }
        })
    }

    private func submitTitle() {
        commitTitle()
        titleFocused = false
        commands.editor?.focusBody()
    }

    private func shownTitle(_ page: Page?) -> String {
        guard let title = page?.title, title != PageService.untitled else { return "" }
        return title
    }

    private func resetTitle() {
        titleOwner = app.notes.page?.id
        titleDraft = shownTitle(app.notes.page)
        titleBaseline = titleDraft
    }

    private func commitTitle() {
        guard let owner = titleOwner else { return }
        let text = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != titleBaseline else { return }
        titleBaseline = text
        Task { await app.notes.rename(owner, to: text) }
    }

    /// A page just made with `/page` is empty and unnamed: the next thing to type is its name.
    private func focusTitleIfNew() {
        guard let page = app.notes.page, page.parentID != nil, page.body.isEmpty,
              page.title == PageService.untitled || page.title.isEmpty else { return }
        Task { @MainActor in titleFocused = true }
    }
}



/// The reader card on the left, the notes on the right, with a grab area between them that you
/// can drag. A plain SwiftUI layout rather than an inspector or `HSplitView`: both cut the window's
/// toolbar in two, and both draw a divider where the sheet should be seamless.
///
/// One stack for all three layouts, so changing layout animates: the reader card keeps its place
/// between "reader and notes" and "reader only" (no reload, no flash) while the notes slide in or
/// out on the right; for "notes only" the card slides out to the left as the notes grow over its
/// place. Slides, never fades, like the sidebar; the card moves rather than shrinks, since a
/// narrowing book would lay its pages out again on every frame.
private struct ReaderNotesLayout<Reader: View, Notes: View>: View {
    let layout: SplitLayout
    @AppStorage("notes.width") private var storedWidth = 380.0
    @State private var dragStart: Double?
    private let reader: Reader
    private let notes: Notes

    init(layout: SplitLayout, @ViewBuilder reader: () -> Reader, @ViewBuilder notes: () -> Notes) {
        self.layout = layout
        self.reader = reader()
        self.notes = notes()
    }

    private static var minNotes: Double { 280 }
    private static var minReader: Double { 340 }

    var body: some View {
        GeometryReader { proxy in
            let widest = max(Self.minNotes, proxy.size.width - Self.minReader)
            let width = min(max(storedWidth, Self.minNotes), widest)
            HStack(spacing: 0) {
                if layout.showsReader {
                    reader.transition(.move(edge: .leading))
                }
                if layout.showsNotes {
                    notes
                        .frame(width: layout == .split ? width : nil)
                        // The grab area lies over the notes' leading margin instead of taking width,
                        // so the gap between the card and the text is exactly one margin.
                        .overlay(alignment: .leading) {
                            if layout == .split { grabArea(current: width, widest: widest) }
                        }
                        .transition(.move(edge: .trailing))
                }
            }
            // A card on its way out stays inside the pane, not over the sidebar or the toolbar.
            .clipped()
            .animation(.smooth(duration: 0.28), value: layout)
        }
    }

    /// No line: the sheet is one surface. Only the pointer tells you the gap can be dragged.
    private func grabArea(current: Double, widest: Double) -> some View {
        Color.clear
            .frame(width: 9)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.resizeLeftRight.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? current
                    dragStart = start
                    storedWidth = min(max(start - drag.translation.width, Self.minNotes), widest)
                }
                .onEnded { _ in dragStart = nil })
    }
}
