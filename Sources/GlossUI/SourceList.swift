import SwiftUI
import GlossAppModel
import GlossCore
import GlossReaderKit

/// The window's source list, sectioned like Mail or Music: the library's shelves and the
/// trash, then, while a book is open, its contents, highlights and notes pages. A click goes through
/// `AppModel.select`, which decides what the detail column shows.
struct SourceList: View {
    let app: AppModel
    /// Bumped by the window whenever this list comes into view (the sidebar opened, the search
    /// results left it): the chapter being read is brought into view then.
    var revealToken = 0
    @Environment(\.undoManager) private var undoManager
    // Which sections are open survives a relaunch, like the rest of the window (state restoration).
    @SceneStorage("sidebar.contents") private var showsContents = true
    @SceneStorage("sidebar.highlights") private var showsHighlights = true
    @SceneStorage("sidebar.notes") private var showsNotes = true

    private var showsBook: Bool {
        if case .book = app.workspace.detail { true } else { false }
    }

    var body: some View {
        ScrollViewReader { proxy in
            list
                // The chapter being read changed (a page turn across a boundary, a jump, a link, a
                // search hit, the book opening): the selection follows it. The list itself never
                // scrolls for this: a click on an entry, or turning pages, leaves it where it is.
                .onChange(of: app.currentContentsRow, initial: true) { _, _ in
                    app.followCurrentContents()
                }
                // The list came into view (the sidebar was closed and opened again, or the search
                // results that covered it ended): bring the chapter being read into view, wherever
                // the list had been left. This is the only time the list scrolls by itself.
                .onChange(of: revealToken) { _, _ in reveal(app.currentContentsRow, with: proxy) }
        }
    }

    /// Scrolls the current chapter's row into view, centred like the system's lists show a row. No
    /// animation: the sidebar should just be right. After this turn of the run loop, so a list
    /// that was just (re)built has its rows to scroll to.
    private func reveal(_ row: ContentsNode.ID?, with proxy: ScrollViewProxy) {
        guard let row, showsContents else { return }
        Task { @MainActor in
            proxy.scrollTo(row, anchor: .center)
        }
    }

    private var list: some View {
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
                let pageCount = app.contentsPageCount
                let current = app.currentContentsRow
                ForEach(OutlineRow.rows(nodes, children: \.children)) { row in
                    let isCurrent = row.node.id == current
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: row.node.label)
                            .lineLimit(2)
                        // Apple Books' "pages left in chapter", under the entry being read.
                        if let pageCount, pageCount.nodeID == row.node.id {
                            Text(verbatim: pageCount.caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, Self.indent(row.depth))
                    // The selection follows the chapter (the standard selected row); VoiceOver
                    // also hears which entry is being read when the selection is elsewhere.
                    .accessibilityValue(isCurrent ? Text("current chapter") : Text(verbatim: ""))
                    // Last, on the row itself: the list reads the selection value from the row's
                    // tag, and a view wrapped around it after the tag (an `.id`, or a modifier with
                    // `if #available`, which the view builder erases to `AnyView`) hid it, so a
                    // click fell back to the ForEach id (a String), matched no `SidebarSelection`
                    // and selected nothing.
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
