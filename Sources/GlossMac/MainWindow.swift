#if os(macOS)
import AppKit
import SwiftUI
import GlossAppModel
import GlossCore
import GlossReaderKit

/// One window: the library in the sidebar, the reader in the detail column. Each window has its
/// own models (AppModel is one window's state) over the shared services.
struct MainWindow: View {
    let root: AppRoot
    @State private var app: AppModel
    @State private var started = false
    @State private var selection: DocumentID?

    init(root: AppRoot) {
        self.root = root
        _app = State(initialValue: AppModel(services: root.services))
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(library: app.library, selection: $selection)
        } detail: {
            if started {
                ReaderPane(reader: app.reader, engines: root.engines)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(app.reader.document?.title ?? "gloss")
        .task { await run() }
        .task(id: selection) { await open(selection) }
        .task(id: app.workspace.readerFocus) { await app.showReaderFocus() }
        .task(id: app.workspace.document?.id) { selection = app.workspace.document?.id }
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
#endif
