#if os(macOS)
import AppKit
import SwiftUI
import GlossAppModel
import GlossCore
import GlossEditor
import GlossNotes
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

    init(root: AppRoot) {
        self.root = root
        _app = State(initialValue: AppModel(services: root.services))
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(library: app.library, selection: $selection)
        } detail: {
            if started {
                // The real split view is milestone 11; this lays the two panes out by the
                // workspace's layout setting so the editor is reachable now.
                HSplitView {
                    if app.workspace.layout.showsReader {
                        ReaderPane(reader: app.reader, engines: root.engines)
                    }
                    if app.workspace.layout.showsNotes {
                        NotesPane(app: app, reveal: reveal, unsavedFailure: $unsavedFailure)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(app.reader.document?.title ?? "gloss")
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
        .alert("couldn't save this page", isPresented: Binding(get: { unsavedFailure != nil },
                                                                set: { if !$0 { unsavedFailure = nil } })) {
            Button("keep editing") { Task { await keepEditing() } }
            Button("discard and switch", role: .destructive) { Task { await switchDiscarding() } }
        } message: {
            Text(verbatim: unsavedFailure ?? "")
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

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            NotesEditor(model: app.notes, reveal: reveal,
                        onOpenGlossLink: { link in await app.follow(link) },
                        onOpenWebLink: { url in _ = NSWorkspace.shared.open(url) },
                        onOpenPage: { id in try? await app.workspace.openPage(id) })
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
