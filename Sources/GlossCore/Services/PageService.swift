import Foundation
import GlossMarkdown

/// A document's page tree, for the sidebar outline and the CLI.
public struct PageTree: Hashable, Sendable {
    public struct Node: Hashable, Sendable {
        public var page: Page
        public var children: [Node]

        public init(page: Page, children: [Node] = []) {
            self.page = page
            self.children = children
        }

        /// Depth-first pages with their depth.
        public func walk(depth: Int = 0) -> [(page: Page, depth: Int)] {
            [(page, depth)] + children.flatMap { $0.walk(depth: depth + 1) }
        }
    }

    public var root: Node

    static func build(root: Page, pages: [Page]) -> PageTree {
        let byParent = Dictionary(grouping: pages.filter { $0.parentID != nil }, by: { $0.parentID! })
        func node(_ page: Page) -> Node {
            Node(page: page, children: (byParent[page.id] ?? []).sorted { ($0.position, $0.id) < ($1.position, $1.id) }.map(node))
        }
        return PageTree(root: node(root))
    }
}

/// Notes pages: reading, creating subpages, saving bodies, renaming.
public struct PageService: Sendable {
    public static let untitled = "untitled"

    let store: any LibraryStore
    let ids: any IDGenerator
    let time: any TimeSource

    public init(store: any LibraryStore, ids: any IDGenerator, time: any TimeSource) {
        self.store = store
        self.ids = ids
        self.time = time
    }

    public func page(_ id: PageID) async throws -> Page? {
        try await store.read { try $0.pages.page(id) }
    }

    public func rootPage(of documentID: DocumentID) async throws -> Page? {
        try await store.read { try $0.pages.rootPage(of: documentID) }
    }

    /// The live page tree of a document.
    public func tree(of documentID: DocumentID) async throws -> PageTree {
        try await store.read { tx in
            guard let root = try tx.pages.rootPage(of: documentID) else { throw GlossError.notFound("the notes for this book") }
            return PageTree.build(root: root, pages: try tx.pages.pages(in: documentID, .live))
        }
    }

    /// Root first, `id` last.
    public func breadcrumbs(to id: PageID) async throws -> [Page] {
        try await store.read { tx in try PageService.ancestry(of: id, in: tx.pages) }
    }

    public func children(of id: PageID) async throws -> [Page] {
        try await store.read { try $0.pages.children(of: id, .live) }
    }

    /// Live children whose block line is missing from the body. They render after the body so
    /// deleting a line never orphans a page.
    public func unplacedChildren(of id: PageID) async throws -> [Page] {
        try await store.read { tx in
            guard let page = try tx.pages.page(id) else { throw GlossError.notFound("that page") }
            let placed = Set(PageBlockLines.find(in: page.body).map(\.pageID))
            return try tx.pages.children(of: id, .live).filter { !placed.contains($0.id) }
        }
    }

    /// Creates a child page. With `appendBlockLine`, also places it at the end of the parent's
    /// body (the CLI does this; the editor inserts the line at the caret itself).
    public func createSubpage(under parentID: PageID, title: String = PageService.untitled, appendBlockLine: Bool = false) async throws -> Page {
        let now = time.now()
        let id: PageID = ids.make()
        return try await store.write { tx in
            guard var parent = try tx.pages.page(parentID) else { throw GlossError.notFound("that page") }
            guard parent.trash == nil else { throw GlossError.inTrash("that page") }
            let siblings = try tx.pages.children(of: parentID, .any)
            let page = Page(id: id, documentID: parent.documentID, parentID: parentID, title: title, body: "",
                            position: (siblings.map(\.position).max() ?? 0) + 1, createdAt: now, updatedAt: now)
            try tx.pages.insert(page)
            try NotesIndexer.index(page, in: tx)
            if appendBlockLine {
                parent.body = QuoteInsertion.insert(PageBlockLines.line(for: id, title: title), into: parent.body, at: nil).body
                parent.updatedAt = now
                try PageService.save(parent, in: tx, now: now)
            }
            return page
        }
    }

    /// Saves a new body (the editor autosaves through this).
    @discardableResult
    public func updateBody(_ id: PageID, to body: String) async throws -> Page {
        let now = time.now()
        return try await store.write { tx in
            guard var page = try tx.pages.page(id) else { throw GlossError.notFound("that page") }
            guard page.trash == nil else { throw GlossError.inTrash("this page") }
            guard page.body != body else { return page }
            page.body = body
            page.updatedAt = now
            try PageService.save(page, in: tx, now: now)
            return page
        }
    }

    /// Renames a page and refreshes block-line labels in its parent that still show the old title.
    @discardableResult
    public func rename(_ id: PageID, to title: String) async throws -> Page {
        let now = time.now()
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await store.write { tx in
            guard var page = try tx.pages.page(id) else { throw GlossError.notFound("that page") }
            let oldTitle = page.title
            guard oldTitle != newTitle else { return page }
            page.title = newTitle
            page.updatedAt = now
            try tx.pages.update(page)
            try NotesIndexer.index(page, in: tx)
            if let parentID = page.parentID, var parent = try tx.pages.page(parentID) {
                let lines = PageBlockLines.find(in: parent.body).filter {
                    $0.pageID == id && PlainText.strip($0.label) == (oldTitle.isEmpty ? PageService.untitled : oldTitle)
                }
                if !lines.isEmpty {
                    let label = MarkdownEscaping.escapeLinkLabel(newTitle.isEmpty ? PageService.untitled : newTitle)
                    let edits = lines.map { TextEdit(range: $0.labelRange, replacement: label) }
                    parent.body = EditResult(edits: edits, selection: 0..<0).apply(to: parent.body)
                    parent.updatedAt = now
                    try PageService.save(parent, in: tx, now: now)
                }
            }
            return page
        }
    }

    /// Appends text to the end of a page as new lines (CLI convenience).
    @discardableResult
    public func append(_ text: String, to id: PageID) async throws -> Page {
        guard let page = try await page(id) else { throw GlossError.notFound("that page") }
        let separator = page.body.isEmpty || page.body.hasSuffix("\n") ? "" : "\n"
        return try await updateBody(id, to: page.body + separator + text)
    }

    // MARK: Transaction-level helpers

    static func save(_ page: Page, in tx: any WriteTransaction, now: Date) throws {
        try tx.pages.update(page)
        try NotesIndexer.index(page, in: tx)
        try ReferenceTracker.update(page, in: tx, now: now)
    }

    static func ancestry(of id: PageID, in pages: any PageReading) throws -> [Page] {
        var chain: [Page] = []
        var cursor = try pages.page(id)
        var seen: Set<PageID> = []
        while let page = cursor, !seen.contains(page.id) {
            seen.insert(page.id)
            chain.insert(page, at: 0)
            cursor = try page.parentID.flatMap { try pages.page($0) }
        }
        guard !chain.isEmpty else { throw GlossError.notFound("that page") }
        return chain
    }

    /// Every live and trashed descendant of `id` (not including it).
    static func descendants(of id: PageID, in pages: any PageReading) throws -> [Page] {
        var result: [Page] = []
        var queue = [id]
        while let next = queue.popLast() {
            let children = try pages.children(of: next, .any)
            result += children
            queue += children.map(\.id)
        }
        return result
    }
}
