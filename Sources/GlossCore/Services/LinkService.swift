import Foundation

/// What a `gloss://` link points at right now.
public enum LinkResolution: Hashable, Sendable {
    case passage(LinkTarget, Document)
    case page(Page, Document)
    case document(Document)
    /// The destination exists but is in the trash.
    case inTrash(title: String, entryID: TrashEntryID?)
    case missing
}

/// A passage that live notes link to, with the pages that do — what the reader draws a marker
/// for and lists when the marker is clicked.
public struct LinkedPassage: Hashable, Sendable {
    public var target: LinkTarget
    public var pages: [Page]

    public init(target: LinkTarget, pages: [Page]) {
        self.target = target
        self.pages = pages
    }
}

/// What the hover popover shows for a passage link.
public struct PassagePreview: Hashable, Sendable {
    public var quote: String
    public var label: String?
    public var documentID: DocumentID
    public var documentTitle: String
}

/// Link targets: creating them for passages, resolving links in both directions.
public struct LinkService: Sendable {
    let store: any LibraryStore
    let ids: any IDGenerator
    let time: any TimeSource

    public init(store: any LibraryStore, ids: any IDGenerator, time: any TimeSource) {
        self.store = store
        self.ids = ids
        self.time = time
    }

    /// The target for a passage, reusing an existing one at the same locator
    /// (docs/DECISIONS.md D-026). New targets start orphaned until a page links to them, so
    /// abandoned ones are swept.
    public func target(for passage: Passage, in documentID: DocumentID) async throws -> LinkTarget {
        let now = time.now()
        let id: LinkTargetID = ids.make()
        return try await store.write { tx in
            try LinkService.target(for: passage, in: documentID, id: id, tx: tx, now: now)
        }
    }

    static func target(for passage: Passage, in documentID: DocumentID, id: LinkTargetID, tx: any WriteTransaction, now: Date) throws -> LinkTarget {
        guard let document = try tx.documents.document(documentID) else { throw GlossError.notFound("that book") }
        guard document.trash == nil else { throw GlossError.inTrash("that book") }
        if let existing = try tx.linkTargets.linkTarget(in: documentID, at: passage.locator) { return existing }
        let target = LinkTarget(id: id, documentID: documentID, passage: passage, createdAt: now, updatedAt: now, orphanedSince: now)
        try tx.linkTargets.insert(target)
        return target
    }

    public func linkTarget(_ id: LinkTargetID) async throws -> LinkTarget? {
        try await store.read { try $0.linkTargets.linkTarget(id) }
    }

    public func resolve(_ link: GlossLink) async throws -> LinkResolution {
        try await store.read { tx in try LinkService.resolve(link, in: tx) }
    }

    static func resolve(_ link: GlossLink, in tx: any ReadTransaction) throws -> LinkResolution {
        func live(_ document: Document) -> LinkResolution? {
            document.trash.map { .inTrash(title: document.title, entryID: $0.entryID) }
        }
        switch link {
        case .document(let id):
            guard let document = try tx.documents.document(id) else { return .missing }
            return live(document) ?? .document(document)
        case .passage(let id):
            guard let target = try tx.linkTargets.linkTarget(id),
                  let document = try tx.documents.document(target.documentID) else { return .missing }
            return live(document) ?? .passage(target, document)
        case .page(let id):
            guard let page = try tx.pages.page(id), let document = try tx.documents.document(page.documentID) else { return .missing }
            if let trashed = live(document) { return trashed }
            if let stamp = page.trash { return .inTrash(title: page.title, entryID: stamp.entryID) }
            return .page(page, document)
        }
    }

    /// Live pages that link to a target, in tree order of their documents.
    public func referringPages(to id: LinkTargetID) async throws -> [Page] {
        try await store.read { tx in try LinkService.livePages(referring: .passage(id), in: tx) }
    }

    static func livePages(referring target: ReferenceTarget, in tx: any ReadTransaction) throws -> [Page] {
        try tx.references.referringPages(to: target).compactMap { id -> Page? in
            guard let page = try tx.pages.page(id), page.trash == nil,
                  let document = try tx.documents.document(page.documentID), document.trash == nil else { return nil }
            return page
        }.sorted { ($0.documentID, $0.position, $0.id) < ($1.documentID, $1.position, $1.id) }
    }

    /// Passages in a document that live notes link to.
    public func linkedPassages(in documentID: DocumentID) async throws -> [LinkedPassage] {
        try await store.read { tx in
            try tx.linkTargets.linkTargets(in: documentID).compactMap { target in
                let pages = try LinkService.livePages(referring: .passage(target.id), in: tx)
                return pages.isEmpty ? nil : LinkedPassage(target: target, pages: pages)
            }
        }
    }

    public func preview(of id: LinkTargetID) async throws -> PassagePreview? {
        try await store.read { tx in
            guard let target = try tx.linkTargets.linkTarget(id), let document = try tx.documents.document(target.documentID) else { return nil }
            return PassagePreview(quote: target.passage.quote, label: target.passage.label, documentID: document.id, documentTitle: document.title)
        }
    }

    /// "add to notes" without an editor (the CLI, or the app when no page is focused): creates
    /// or reuses the target and inserts a quote line at `offset`, or at the end of the page.
    public func addQuote(of passage: Passage, in documentID: DocumentID, to pageID: PageID, at offset: Int? = nil) async throws -> (page: Page, target: LinkTarget, insertedRange: Range<Int>) {
        let now = time.now()
        let id: LinkTargetID = ids.make()
        return try await store.write { tx in
            let target = try LinkService.target(for: passage, in: documentID, id: id, tx: tx, now: now)
            guard var page = try tx.pages.page(pageID) else { throw GlossError.notFound("that page") }
            guard page.trash == nil else { throw GlossError.inTrash("that page") }
            let insertion = QuoteInsertion.insert(QuoteLine.make(quote: passage.quote, target: target.id), into: page.body, at: offset)
            page.body = insertion.body
            page.updatedAt = now
            try PageService.save(page, in: tx, now: now)
            return (page, target, insertion.insertedRange)
        }
    }
}
