import Foundation
import Observation
import GlossCore
import GlossReaderBridge

/// What is selected in the window's source list (D-101). One list, sectioned like Mail or Music:
/// the library's shelves and the trash, then the open book's contents, highlights and notes
/// pages. The selection decides the detail column.
public enum SidebarSelection: Hashable, Sendable {
    /// A shelf of the library grid (`nil` is "all").
    case library(LibraryShelf?)
    case trash
    /// The open book with nothing in particular selected (opened from the grid or a link).
    case book
    /// An entry of the book's table of contents.
    case contents(ContentsNode.ID)
    case highlight(HighlightID)
    case page(PageID)

    /// Whether this selection shows the reader and notes (rather than the grid or the trash).
    public var showsBook: Bool {
        switch self {
        case .library, .trash: false
        case .book, .contents, .highlight, .page: true
        }
    }
}

/// What the detail column shows.
public enum SidebarDetail: Hashable, Sendable {
    case library(LibraryShelf?)
    case trash
    case book
}

/// One entry of the table of contents, nested as the book nests them. `children` is nil for a
/// leaf (what `OutlineGroup` expects).
public struct ContentsNode: Hashable, Identifiable, Sendable {
    /// The entry's place in the tree ("0", "0.2", …): stable for a book, unique even when two
    /// entries point at the same place.
    public var id: String
    public var label: String
    public var target: Locator
    public var children: [ContentsNode]?

    /// The tree for a table of contents.
    public static func nodes(from toc: [ReaderTocEntry], prefix: String = "") -> [ContentsNode] {
        toc.enumerated().map { index, entry in
            let id = prefix.isEmpty ? String(index) : "\(prefix).\(index)"
            let children = nodes(from: entry.children, prefix: id)
            return ContentsNode(id: id, label: entry.label, target: entry.target, children: children.isEmpty ? nil : children)
        }
    }

    /// The node with an id, searching the whole tree.
    public static func find(_ id: ID, in nodes: [ContentsNode]) -> ContentsNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = find(id, in: node.children ?? []) { return found }
        }
        return nil
    }
}

/// A tree laid out as rows with their depth, in order: the source list indents nested entries
/// itself instead of using expandable outline rows, whose disclosure triangles made the sidebar
/// shift every row, the library's too, whenever a book was open (D-147).
public struct OutlineRow<Node: Identifiable>: Identifiable {
    public let node: Node
    public let depth: Int
    public var id: Node.ID { node.id }

    public static func rows(_ nodes: [Node], children: KeyPath<Node, [Node]?>, depth: Int = 0) -> [OutlineRow<Node>] {
        nodes.flatMap { node in
            [OutlineRow(node: node, depth: depth)] + rows(node[keyPath: children] ?? [], children: children, depth: depth + 1)
        }
    }
}

/// One notes page in the sidebar's read-only outline (brief 25: no drag to reorder).
public struct PageOutlineNode: Hashable, Identifiable, Sendable {
    public var id: PageID
    public var title: String
    public var children: [PageOutlineNode]?

    init(_ node: PageTree.Node) {
        id = node.page.id
        let title = node.page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.isEmpty ? PageService.untitled : title
        let children = node.children.map(PageOutlineNode.init)
        self.children = children.isEmpty ? nil : children
    }
}

/// Which books the source list's book section is about: the reader's (its contents and
/// highlights) and the notes pane's (its pages). They differ after following a cross-book link
/// (D-102).
public struct BookSidebarSubjects: Hashable, Sendable {
    public var reader: DocumentID?
    public var notes: DocumentID?

    public init(reader: DocumentID?, notes: DocumentID?) {
        self.reader = reader
        self.notes = notes ?? reader
    }
}

/// The open book's part of the source list: the reader's book's highlights in reading order and
/// the notes pane's book's pages as a tree (the contents come from the reader, which reads them
/// from the book).
@MainActor @Observable public final class BookSidebarModel {
    /// The reader's book.
    public private(set) var documentID: DocumentID?
    public private(set) var highlights: [Highlight] = []
    /// The book whose pages `pages` lists (the notes pane's).
    public private(set) var notesDocumentID: DocumentID?
    public private(set) var pages: [PageOutlineNode] = []
    /// The notes' book's title when it isn't the reader's book (the notes section names it).
    public private(set) var notesTitle: String?

    private let services: GlossServices
    /// Bumped by every load; only the newest may publish (a slow read for the previous book must
    /// not land on the next one).
    private var generation = 0

    public init(services: GlossServices) {
        self.services = services
    }

    /// Shows one book's highlights and pages, or nothing.
    public func load(_ documentID: DocumentID?) async {
        await load(BookSidebarSubjects(reader: documentID, notes: nil))
    }

    /// Shows the reader's book's highlights and the notes' book's pages.
    public func load(_ subjects: BookSidebarSubjects) async {
        generation += 1
        let mine = generation
        guard let reader = subjects.reader else {
            documentID = nil
            notesDocumentID = nil
            highlights = []
            pages = []
            notesTitle = nil
            return
        }
        let notes = subjects.notes ?? reader
        let found = try? await services.highlights.highlights(in: reader)
        let tree = try? await services.pages.tree(of: notes)
        let title = notes == reader ? nil : try? await services.library.document(notes)?.title
        guard mine == generation else { return }
        if documentID != reader {
            documentID = reader
            highlights = []
        }
        if notesDocumentID != notes {
            notesDocumentID = notes
            pages = []
            notesTitle = nil
        }
        // A failed read keeps what is shown.
        if let found { highlights = Self.readingOrder(found) }
        if let tree { pages = [PageOutlineNode(tree.root)] }
        if notes == reader { notesTitle = nil } else if let title { notesTitle = title }
    }

    /// Reloads what is shown (after edits here or elsewhere).
    public func refresh() async {
        await load(BookSidebarSubjects(reader: documentID, notes: notesDocumentID))
    }

    /// Book order: by where the passage sits, then by when it was made.
    static func readingOrder(_ highlights: [Highlight]) -> [Highlight] {
        highlights.sorted {
            ($0.passage.progression ?? 0, $0.createdAt, $0.id.stringValue) < ($1.passage.progression ?? 0, $1.createdAt, $1.id.stringValue)
        }
    }
}
