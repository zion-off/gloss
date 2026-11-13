#if os(macOS)
import SwiftUI
import GlossAppModel
import GlossCore
import GlossReaderKit

/// The window's source list (D-101), sectioned like Mail or Music: the library's shelves and the
/// trash, then the open book with its contents, highlights and notes pages. A click goes through
/// `AppModel.select`, which decides what the detail column shows.
struct SourceList: View {
    let app: AppModel
    @Environment(\.undoManager) private var undoManager
    // Which sections are open survives a relaunch, like the rest of the window (state restoration).
    @SceneStorage("sidebar.contents") private var showsContents = true
    @SceneStorage("sidebar.highlights") private var showsHighlights = true
    @SceneStorage("sidebar.notes") private var showsNotes = true

    var body: some View {
        List(selection: selection) {
            Section("library") {
                Label("all", systemImage: "books.vertical")
                    .tag(SidebarSelection.library(nil))
                ForEach(app.library.availableShelves, id: \.self) { shelf in
                    // A shelf's name is data ("books", "pdfs"), not a localization key.
                    Label(shelf.rawValue, systemImage: app.library.symbol(of: shelf))
                        .tag(SidebarSelection.library(shelf))
                }
                Label("trash", systemImage: "trash")
                    .badge(app.trash.items.count)
                    .tag(SidebarSelection.trash)
            }
            if let document = app.workspace.document {
                Section("reading") {
                    Label(document.title, systemImage: app.library.symbol(of: document.kind))
                        .lineLimit(2)
                        .tag(SidebarSelection.book)
                }
                contents
                highlights
                notes
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand(perform: deleteSelectedHighlight)
    }

    /// Clicks go to the app model; it updates `workspace.sidebar`, which the list reads back.
    /// Nothing is ever deselected: a click on empty space keeps what the detail column shows.
    private var selection: Binding<SidebarSelection?> {
        Binding(get: { app.workspace.sidebar }, set: { new in
            guard let new, new != app.workspace.sidebar else { return }
            Task { await app.select(new) }
        })
    }

    // MARK: The open book

    /// The book's table of contents, nested as the book nests it (none for a book without one).
    @ViewBuilder private var contents: some View {
        let nodes = app.contents
        if !nodes.isEmpty {
            Section("contents", isExpanded: $showsContents) {
                OutlineGroup(nodes, children: \.children) { node in
                    Text(verbatim: node.label)
                        .lineLimit(2)
                        .tag(SidebarSelection.contents(node.id))
                }
            }
        }
    }

    /// The book's highlights in reading order (brief 8): click to jump, delete to remove.
    private var highlights: some View {
        Section("highlights", isExpanded: $showsHighlights) {
            if app.bookSidebar.highlights.isEmpty {
                // No tag: a hint, not something to select.
                Text("nothing highlighted yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(app.bookSidebar.highlights) { highlight in
                HighlightRow(highlight: highlight)
                    .tag(SidebarSelection.highlight(highlight.id))
                    .contextMenu {
                        Button("remove highlight", role: .destructive) {
                            app.reader.removeHighlight(highlight, undo: undoManager)
                        }
                    }
            }
        }
    }

    /// The book's notes pages as a read-only tree (brief 25: no drag to reorder or reparent).
    private var notes: some View {
        Section("notes", isExpanded: $showsNotes) {
            OutlineGroup(app.bookSidebar.pages, children: \.children) { page in
                // The editor's subpage rows use the same symbol.
                Label(page.title, systemImage: "doc.text")
                    .lineLimit(1)
                    .tag(SidebarSelection.page(page.id))
            }
        }
    }

    /// Edit › Delete (and the delete key) on a selected highlight removes it, undoably.
    private func deleteSelectedHighlight() {
        guard case .highlight(let id) = app.workspace.sidebar,
              let highlight = app.bookSidebar.highlights.first(where: { $0.id == id }) else { return }
        app.reader.removeHighlight(highlight, undo: undoManager)
    }
}

/// One highlight: its colour, the passage, and where it sits.
private struct HighlightRow: View {
    let highlight: Highlight

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(highlight.color.swatch)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: highlight.passage.quote)
                    .lineLimit(2)
                if let label = highlight.passage.label, !label.isEmpty {
                    Text(verbatim: label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(highlight.color.rawValue) highlight: \(highlight.passage.quote)"))
    }
}
#endif
