#if os(macOS)
import AppKit
import SwiftUI
import GlossAppModel
import GlossCore
import GlossEditor
import GlossNotes
import GlossReaderBridge
import GlossReaderKit

/// One window: the library in the sidebar, the reader in the detail column. Each window has its
/// own models (AppModel is one window's state) over the shared services.
struct MainWindow: View {
    let root: AppRoot
    @State private var app: AppModel
    @State private var started = false
    @State private var selection: DocumentID?
    @State private var reveal: NotesReveal?
    @State private var unsavedFailure: String?
    @State private var commands: WindowCommands
    /// The reader's engine session lives with the window, so hiding the reader keeps the book.
    @State private var readerHost = ReaderSessionHost()

    init(root: AppRoot) {
        self.root = root
        let app = AppModel(services: root.services)
        let commands = WindowCommands()
        commands.bind(app)
        _app = State(initialValue: app)
        _commands = State(initialValue: commands)
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(library: app.library, selection: $selection)
        } detail: {
            if started {
                // Reader and notes side by side with a draggable divider; the View menu and the
                // toolbar switch the layout (persisted, shared by all windows).
                HSplitView {
                    if app.workspace.layout.showsReader {
                        ReaderPane(reader: app.reader, engines: root.engines, host: readerHost,
                                   addToNotes: { await commands.addToNotes() })
                            .frame(minWidth: 320)
                    }
                    if app.workspace.layout.showsNotes {
                        NotesPane(app: app, reveal: reveal, unsavedFailure: $unsavedFailure,
                                  commands: commands)
                            .frame(minWidth: 280)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(app.reader.document?.title ?? "gloss")
        .toolbar { toolbar }
        .focusedSceneValue(\.windowCommands, commands)
        .task { await run() }
        .task(id: selection) { await open(selection) }
        .task(id: app.workspace.readerFocus) { await app.showReaderFocus() }
        .task(id: app.workspace.document?.id) { selection = app.workspace.document?.id }
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

    /// Starts the window, then polls for changes from the cli and other windows once a second
    /// until the window closes (the task is cancelled with it).
    private func run() async {
        await root.prepare()
        await app.workspace.loadPersistedLayout()
        app.reader.openExternal = { url in _ = NSWorkspace.shared.open(url) }
        await app.library.reload()
        await app.startMonitoringChanges()
        started = true
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            await app.changeMonitor?.poll()
        }
    }

    private func open(_ id: DocumentID?) async {
        guard let id, id != app.workspace.document?.id else { return }
        // A book that just went (trashed from the cli) stays unopened; the next poll drops it.
        try? await app.workspace.openDocument(id)
    }
}

/// The library as a plain source list (the cover grid comes in milestone 12).
struct LibrarySidebar: View {
    let library: LibraryModel
    @Binding var selection: DocumentID?

    var body: some View {
        List(selection: $selection) {
            ForEach(library.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.document.title)
                        .lineLimit(2)
                    if !entry.document.author.isEmpty {
                        Text(verbatim: entry.document.author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .tag(entry.id)
            }
        }
        .overlay {
            if library.entries.isEmpty {
                ContentUnavailableView("no books yet", systemImage: "books.vertical",
                                       description: Text("add some with gloss import in terminal"))
            }
        }
    }
}

/// The notes half of the window: breadcrumbs, the editor, and a note when a save failed.
struct NotesPane: View {
    let app: AppModel
    let reveal: NotesReveal?
    @Binding var unsavedFailure: String?
    /// The window's commands: ⌘K, add to notes and history reach the editor through these.
    let commands: WindowCommands

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            NotesEditor(model: app.notes, reveal: reveal,
                        onOpenGlossLink: { link in await app.follow(link) },
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
