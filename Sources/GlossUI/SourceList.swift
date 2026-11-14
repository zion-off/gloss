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
    /// The contents rows fully on screen (macOS 15's scroll visibility). On earlier systems it
    /// stays empty and a due scroll always runs: centring a row that was visible is harmless.
    @State private var fullyVisibleRows: Set<ContentsNode.ID> = []
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
                // search hit, the book opening): the selection follows it, and its row comes into
                // view. Same-entry relocations (resizes, restyles, page turns inside it) change
                // nothing, so a sidebar the user scrolled by hand stays put until the chapter does.
                .onChange(of: app.currentContentsRow, initial: true) { previous, current in
                    app.followCurrentContents()
                    // The initial call (the book opened, the list was rebuilt) passes the same value
                    // twice: that counts as arriving at the chapter, so it scrolls too.
                    if ContentsVisibility.shouldScroll(previous: previous == current ? nil : previous, current: current) {
                        reveal(current, with: proxy)
                    }
                }
                // The list came into view (the sidebar opened, the search ended): bring the chapter
                // being read into view, wherever the list had been left.
                .onChange(of: revealToken) { _, _ in reveal(app.currentContentsRow, with: proxy) }
                // Another book: its rows replaced the old ones, and entry ids are per-book
                // positions, so the same id ("1") in both books is no change to observe — the
                // book switching is.
                .onChange(of: app.workspace.document?.id) { _, _ in reveal(app.currentContentsRow, with: proxy) }
        }
    }

    /// Scrolls the current chapter's row into view, centred like the system's lists show a row,
    /// unless it is already fully visible. No animation: the sidebar should just be right. After
    /// this turn of the run loop, so a list that was just (re)built has its rows to scroll to.
    private func reveal(_ row: ContentsNode.ID?, with proxy: ScrollViewProxy) {
        guard let row, showsContents else { return }
        Task { @MainActor in
            guard !fullyVisibleRows.contains(row) else { return }
            proxy.scrollTo(Self.contentsRowID(row), anchor: .center)
        }
    }

    /// A contents row's scroll id, apart from the other sections' row ids.
    static func contentsRowID(_ id: ContentsNode.ID) -> String { "contents:" + id }

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
                    .tag(SidebarSelection.contents(row.node.id))
                    .id(Self.contentsRowID(row.node.id))
                    // The selection follows the chapter (the standard selected row); VoiceOver
                    // also hears which entry is being read when the selection is elsewhere.
                    .accessibilityValue(isCurrent ? Text("current chapter") : Text(verbatim: ""))
                    .modifier(FullVisibility(id: row.node.id, visible: $fullyVisibleRows))
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

/// Tracks which contents rows are fully on screen (macOS 15+), so a due scroll can leave a
/// visible row alone. Earlier systems never record any: the scroll always runs.
private struct FullVisibility: ViewModifier {
    let id: ContentsNode.ID
    @Binding var visible: Set<ContentsNode.ID>

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollVisibilityChange(threshold: 0.99) { isVisible in
                    if isVisible { visible.insert(id) } else { visible.remove(id) }
                }
                .onDisappear { visible.remove(id) }
        } else {
            content
        }
    }
}
