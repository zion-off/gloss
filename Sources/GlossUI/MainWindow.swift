#if os(macOS)
import AppKit
import SwiftUI
import GlossAppModel
import GlossCore
import GlossEditor
import GlossNotes
import GlossReaderBridge
import GlossReaderKit

/// One window: the source list in the sidebar (D-101); the library, the trash or the open book in
/// the detail column. Each window has its own models (AppModel is one window's state) over the
/// shared services, which the composition root (GlossMac) hands in with the reading engines.
public struct MainWindow: View {
    @Environment(\.undoManager) private var undoManager
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
    public init(services: GlossServices, engines: ReadingEngineRegistry, export: ExportModel? = nil,
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
        _backup = State(initialValue: BackupCommands(services: services))
    }

    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var showsBook: Bool {
        if case .book = app.workspace.detail { true } else { false }
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SourceList(app: app)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 360)
        } detail: {
            detailColumn
                // A click on empty space takes focus from the search field (and any other field):
                // a plain background view never asks for it, so it stayed in the field.
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { NSApp.keyWindow?.makeFirstResponder(nil) })
        }
        // A book gets the whole window: the sidebar steps aside when one opens and returns for the
        // library and the trash, where it is the way around. Opening it by hand inside a book sticks
        // until the next change of place.
        .onChange(of: showsBook, initial: true) { _, isBook in
            withAnimation { columnVisibility = isBook ? .detailOnly : .all }
        }
        .navigationTitle(title)
        .hidingSystemTitle()
        .toolbar { toolbar }
        .glossSearch(model: app.search)
        .libraryFeatures(app: app)  // the drop zone, ⇧⌘A, the import alert, the details sheet, the sort menu
        .quickSwitcher(app: app, isPresented: Binding(get: { commands.showsSwitcher },
                                                       set: { commands.showsSwitcher = $0 }))
        .externalURLHandling(app: app)
        .exportFailureAlert(app: app)
        .focusedSceneValue(\.windowCommands, commands)
        .focusedSceneValue(\.exportActions, exportActions)
        .focusedSceneValue(\.backupCommands, backup)
        .backupResultAlert(backup)
        .overlay(alignment: .bottom) { TrashToastOverlay(app: app) }
        .task { await run() }
        .task(id: app.workspace.readerFocus) { await app.showReaderFocus() }
        .task(id: app.bookSidebarSubjects) {
            await app.showBookSidebar()
            // The search scope follows the context: opening a book (or going home) adopts the
            // default for where the user now is (brief 32).
            app.search.resetToDefaultScope()
        }
        .task(id: app.workspace.pendingNoteReveal) {
            if let range = app.workspace.pendingNoteReveal, let page = app.workspace.page {
                reveal = NotesReveal(pageID: page.id, range: range)
                app.workspace.consumeNoteReveal()
            }
        }
        .alert("this page has unsaved changes", isPresented: Binding(get: { unsavedFailure != nil },
                                                                        set: { if !$0 { unsavedFailure = nil } })) {
            // Cancel role so Escape means "keep editing" too: the natural way out of a
            // refuse-to-switch alert (review 5).
            Button("keep editing", role: .cancel) { Task { await keepEditing() } }
            Button("discard and switch", role: .destructive) { Task { await switchDiscarding() } }
        } message: {
            Text(verbatim: "the last save failed (\(unsavedFailure ?? "something went wrong")). switching pages would drop what you typed.")
        }
        .onDisappear {
            // The window is going away: nothing will fire the debounced save or the position
            // write anymore. Flush both so up to half a second of typing isn't lost (review 5),
            // and the layout and sort choices too — their persist chains hold the window weakly,
            // so the last ⌥⌘1/2/3 or sort click would otherwise die with it (review 7).
            Task { await app.notes.flushSave() }
            Task { await app.reader.flushPosition() }
            Task { await app.workspace.flushLayoutPersistence() }
            Task { await app.library.flushSortPersistence() }
        }
    }

    @ViewBuilder private var detailColumn: some View {
            if started {
                if app.search.hasQuery {
                    // Searching replaces the detail column, Mail-style (D-130); choosing a hit
                    // dismisses the search and jumps there.
                    SearchResults(app: app)
                } else {
                    switch app.workspace.detail {
                    case .library:
                        LibraryGrid(library: app.library, presentation: app.presentation, open: open,
                                   moveToTrash: moveToTrash)
                    case .trash:
                        TrashView(trash: app.trash)
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
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
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

    /// Whether the title is drawn by our toolbar (it is where the system one can be removed).
    private static let titleInToolbar: Bool = {
        if #available(macOS 15.0, *) { true } else { false }
    }()

    /// Back and forward, then the title, on the leading edge (Finder, Safari); the layout switch
    /// right beside the search field on the trailing side. Back/forward is its own item, a
    /// `ControlGroup` in the navigation style, so the system draws Finder's grouped pair (one
    /// capsule, system chevrons, hover and disabled states); the title is a second navigation
    /// item after it, without a capsule of its own (D-150).
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { backForward }
        if Self.titleInToolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { titleLabel }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { titleLabel }
            }
        }
        // Only while the book is on screen: on the library or the trash there is no reader to lay out.
        if case .book = app.workspace.detail {
            ToolbarItem(placement: .primaryAction) {
                Picker("layout", selection: Binding(get: { commands.layout }, set: { commands.layout = $0 })) {
                    Label("reader and notes", systemImage: "rectangle.split.2x1").tag(SplitLayout.split)
                    Label("reader only", systemImage: "book").tag(SplitLayout.readerOnly)
                    Label("notes only", systemImage: "note.text").tag(SplitLayout.notesOnly)
                }
                .pickerStyle(.segmented)
                .help("layout (⌥⌘1, ⌥⌘2, ⌥⌘3)")
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

    private var titleLabel: some View {
        Text(verbatim: title).font(.headline).lineLimit(1)
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

/// The notes half of the window: breadcrumbs, the editor, and a note when a save failed.
struct NotesPane: View {
    let app: AppModel
    let reveal: NotesReveal?
    @Binding var unsavedFailure: String?
    /// The window's commands: ⌘K, add to notes and history reach the editor through these.
    let commands: WindowCommands
    /// Why the last link clicked in the notes went nowhere (shown in an alert).
    @State private var linkProblem: RouteProblem?
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
            NotesEditor(model: app.notes, reveal: reveal,
                        onOpenGlossLink: { link in linkProblem = await app.follow(link).problem },
                        onOpenWebLink: { url in _ = NSWorkspace.shared.open(url) },
                        onOpenPage: { id in Task { try? await app.workspace.openPage(id) } },
                        actions: { actions in
                            commands.editor = actions
                            actions.onFocusChange = { focused in commands.notesFocused = focused }
                        })
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
        }
        .task(id: app.workspace.page?.id) { await loadPage() }
        .onChange(of: app.notes.page?.id, initial: true) { _, _ in
            commitTitle()  // for the page that was showing, before the field changes hands
            resetTitle()
            focusTitleIfNew()
        }
        .onChange(of: app.notes.page?.title) { _, _ in
            if !titleFocused { resetTitle() }  // renamed elsewhere (another window, the cli)
        }
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// The page's own title, above its body (brief 21). Return or leaving the field saves it.
    private var titleField: some View {
        TextField("untitled", text: $titleDraft)
            .textFieldStyle(.plain)
            .font(.title.bold())
            .focused($titleFocused)
            .onSubmit { commitTitle() }
            .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
            .padding(.leading, 17)  // the text's own inset (12 + the line fragment padding)
            .padding(.trailing, 12)
            .padding(.top, 14)
            .padding(.bottom, 2)
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

    private func loadPage() async {
        guard let page = app.workspace.page else { return }
        do {
            try await app.notes.load(page)
        } catch let NotesEditorModel.EditorError.unsavedChanges(reason) {
            unsavedFailure = reason
        } catch {}
    }
}

extension View {
    /// Takes the system's title out of the toolbar where the SDK allows it (macOS 15+), so the
    /// toolbar can draw it after back and forward. Older systems keep the system title.
    @ViewBuilder fileprivate func hidingSystemTitle() -> some View {
        if #available(macOS 15.0, *) { self.toolbar(removing: .title) } else { self }
    }
}


/// The reader card on the left, the notes on the right, with a grab area between them that you
/// can drag. A plain SwiftUI layout rather than an inspector or `HSplitView`: both cut the window's
/// toolbar in two, and both draw a divider where the sheet should be seamless.
///
/// One stack for all three layouts, so changing layout animates: the reader card keeps its place
/// between "reader and notes" and "reader only" (no reload, no flash) while the notes slide and
/// fade in or out.
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
                    reader.transition(.opacity)
                }
                if layout == .split {
                    grabArea(current: width, widest: widest)
                }
                if layout.showsNotes {
                    notes
                        .frame(width: layout == .split ? width : nil)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
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
#endif
