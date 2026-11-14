import SwiftUI
import GlossAppModel
import GlossCore
import GlossReaderKit

/// The window's source list, sectioned like Mail or Music: the library's shelves and the
/// trash, then, while a book is open, its contents, highlights and notes pages. A click goes through
/// `AppModel.select`, which decides what the detail column shows.
struct SourceList: View {
    let app: AppModel
    @Environment(\.undoManager) private var undoManager
    // Which sections are open survives a relaunch, like the rest of the window (state restoration).
    @SceneStorage("sidebar.contents") private var showsContents = true
    @SceneStorage("sidebar.highlights") private var showsHighlights = true
    @SceneStorage("sidebar.notes") private var showsNotes = true

    private var showsBook: Bool {
        if case .book = app.workspace.detail { true } else { false }
    }

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
            // The book's own sections belong to the book: on the library or the trash they
            // would point at something the window isn't showing. No row for the book itself: it
            // is what the window already shows, so picking it did nothing.
            if case .book = app.workspace.detail {
                contents
                highlights
                notes
            }
        }
        .listStyle(.sidebar)
        // The book's sections come and go with the detail column; SwiftUI left one of their rows
        // behind in the list when they went (a stray page row on the library), so the list is
        // rebuilt on the change. Selection and expansion live outside it.
        .id(showsBook)
        .onDeleteCommand(perform: deleteSelection)
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

    /// The book's table of contents, indented as the book nests it (none for a book without one).
    @ViewBuilder private var contents: some View {
        let nodes = app.contents
        if !nodes.isEmpty {
            Section("contents", isExpanded: $showsContents) {
                ForEach(OutlineRow.rows(nodes, children: \.children)) { row in
                    Text(verbatim: row.node.label)
                        .lineLimit(2)
                        .padding(.leading, Self.indent(row.depth))
                        .tag(SidebarSelection.contents(row.node.id))
                }
            }
        }
    }

    /// The book's highlights in reading order: click to jump, delete to remove.
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

    /// The notes pane's pages as a read-only tree (brief 25: no drag to reorder or reparent).
    /// After a cross-book link they belong to another book than the reader's, and the header
    /// says which. Anything but the root can go to the trash; the root goes
    /// with its book.
    private var notes: some View {
        Section(isExpanded: $showsNotes) {
            ForEach(OutlineRow.rows(app.bookSidebar.pages, children: \.children)) { row in
                let page = row.node
                // The editor's subpage rows use the same symbol.
                Label(page.title, systemImage: "doc.text")
                    .lineLimit(1)
                    .padding(.leading, Self.indent(row.depth))
                    .tag(SidebarSelection.page(page.id))
                    .contextMenu {
                        if page.id != app.bookSidebar.pages.first?.id {
                            Button("move to trash", role: .destructive) {
                                app.trashPage(page.id, undoManager: undoManager)
                            }
                        }
                    }
            }
        } header: {
            if let title = app.bookSidebar.notesTitle {
                Text(verbatim: "notes · \(title)")
            } else {
                Text("notes")
            }
        }
    }

    /// How far a nested contents entry or notes page sits in, per level: the trees are indented
    /// rows, not expandable outline rows, so every row keeps the library's alignment.
    static func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 14 }

    /// Edit › Delete (and the delete key) removes the selection: a highlight or a notes page. A
    /// page that can't go to the trash says so in a toast. A book with nothing selected in it has
    /// no row, so delete does nothing then (it must not trash the open book unseen).
    private func deleteSelection() {
        switch app.workspace.sidebar {
        case .highlight(let id):
            guard let highlight = app.bookSidebar.highlights.first(where: { $0.id == id }) else { return }
            app.reader.removeHighlight(highlight, undo: undoManager)
        case .page(let id):
            app.trashPage(id, undoManager: undoManager)
        case .library, .trash, .contents, .book:
            break
        }
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
