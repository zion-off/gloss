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
    private let engines: ReadingEngineRegistry
    private let prepare: @MainActor () async -> Void
    @State private var app: AppModel
    @State private var started = false
    @State private var reveal: NotesReveal?
    @State private var unsavedFailure: String?
    @State private var commands: WindowCommands
    /// The reader's engine session lives with the window, so hiding the reader keeps the book.
    @State private var readerHost = ReaderSessionHost()

    /// - Parameter prepare: once-per-launch setup to await before the first book shows
    ///   (reading settings, routine upkeep); every window calls it, the root runs it once.
    public init(services: GlossServices, engines: ReadingEngineRegistry,
                prepare: @escaping @MainActor () async -> Void) {
        self.engines = engines
        self.prepare = prepare
        let app = AppModel(services: services)
        let commands = WindowCommands()
        commands.bind(app)
        _app = State(initialValue: app)
        _commands = State(initialValue: commands)
    }

    public var body: some View {
        NavigationSplitView {
            SourceList(app: app)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 360)
        } detail: {
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
                        ContentUnavailableView("trash", systemImage: "trash")
                    case .book:
                        book
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .toolbar { toolbar }
        .glossSearch(model: app.search)
        .focusedSceneValue(\.windowCommands, commands)
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
            // write anymore. Flush both so up to half a second of typing isn't lost (review 5).
            Task { await app.notes.flushSave() }
            Task { await app.reader.flushPosition() }
        }
    }

    /// Reader and notes side by side with a draggable divider; the View menu and the toolbar
    /// switch the layout (persisted, shared by all windows). The reader's session lives in
    /// `readerHost`, so showing the library and coming back keeps the book where it was.
    private var book: some View {
        HSplitView {
            if app.workspace.layout.showsReader {
                ReaderPane(reader: app.reader, engines: engines, host: readerHost,
                           addToNotes: { await commands.addToNotes() })
                    .frame(minWidth: 320)
            }
            if app.workspace.layout.showsNotes {
                NotesPane(app: app, reveal: reveal, unsavedFailure: $unsavedFailure,
                          commands: commands)
                    .frame(minWidth: 280)
            }
        }
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

    /// Back/forward on the leading edge (Safari, Finder); the layout switch on the trailing side.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button { commands.goBack() } label: { Label("back", systemImage: "chevron.left") }
                    .disabled(!commands.canGoBack)
                    .help("back (⌘[)")
                Button { commands.goForward() } label: { Label("forward", systemImage: "chevron.right") }
                    .disabled(!commands.canGoForward)
                    .help("forward (⌘])")
            }
        }
        ToolbarItem {
            Picker("layout", selection: Binding(get: { commands.layout }, set: { commands.layout = $0 })) {
                Label("reader and notes", systemImage: "rectangle.split.2x1").tag(SplitLayout.split)
                Label("reader only", systemImage: "book").tag(SplitLayout.readerOnly)
                Label("notes only", systemImage: "note.text").tag(SplitLayout.notesOnly)
            }
            .pickerStyle(.segmented)
            .help("layout (⌥⌘1, ⌥⌘2, ⌥⌘3)")
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
        _ = document
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

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
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

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            ForEach(Array(app.notes.breadcrumbs.dropLast().enumerated()), id: \.offset) { _, page in
                Button(page.title) { Task { try? await app.workspace.openPage(page.id) } }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                Text(verbatim: "›").foregroundStyle(.tertiary)
            }
            if let page = app.notes.breadcrumbs.last {
                Text(verbatim: page.title).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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
#endif
