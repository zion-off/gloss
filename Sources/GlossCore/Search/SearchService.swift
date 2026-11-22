import Foundation
import GlossMarkdown

/// A results group in the search popover. Open: a new source can bring its own group.
public struct SearchResultGroup: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Lower comes first.
    public var order: Int

    public init(id: String, title: String, order: Int) {
        self.id = id
        self.title = title
        self.order = order
    }

    public static let notes = SearchResultGroup(id: "notes", title: "notes", order: 0)
    public static let bookText = SearchResultGroup(id: "book-text", title: "in the book", order: 1)
    public static let library = SearchResultGroup(id: "library", title: "library", order: 2)
}

/// Where selecting a hit goes.
public enum SearchDestination: Hashable, Sendable {
    case document(DocumentID)
    /// A notes page, with the hit's UTF-16 range in the body to highlight (nil: title hit).
    case page(PageID, DocumentID, match: Range<Int>?)
    /// One match in the book: the text chunk it is in (`locator`), the matched words, and where
    /// they are in the chunk's extracted text (UTF-16), from which `SearchService.anchor` pins the
    /// match for the engine to find again. Without a match range, the engine finds `matchText`
    /// near `locator`.
    case bookText(DocumentID, locator: Locator?, matchText: String, match: Range<Int>?)
}

public struct SearchHit: Hashable, Sendable {
    public var group: SearchResultGroup
    public var title: String
    public var subtitle: String?
    public var snippet: Snippet
    public var destination: SearchDestination

    public init(group: SearchResultGroup, title: String, subtitle: String? = nil, snippet: Snippet,
                destination: SearchDestination) {
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.snippet = snippet
        self.destination = destination
    }
}

public struct SearchResultSection: Hashable, Sendable, Identifiable {
    public var group: SearchResultGroup
    public var hits: [SearchHit]
    public var id: String { group.id }

    public init(group: SearchResultGroup, hits: [SearchHit]) {
        self.group = group
        self.hits = hits
    }
}

/// A searchable source. Register one to make something new searchable.
public protocol SearchSource: Sendable {
    /// Hits for `query` within `scope`, at most `limit` (nil: all of them), or none if the
    /// source does not cover that scope.
    func search(_ query: String, in scope: SearchScope, limit: Int?, tx: any ReadTransaction) throws -> [SearchHit]
}

/// Runs every registered source and groups the results.
public struct SearchService: Sendable {
    let store: any LibraryStore
    let sources: [any SearchSource]

    public init(store: any LibraryStore, sources: [any SearchSource] = SearchService.standardSources) {
        self.store = store
        self.sources = sources
    }

    public static let standardSources: [any SearchSource] = [NotesSearchSource(), BookTextSearchSource(), LibrarySearchSource()]

    /// Every hit of every source, unless `limit` caps each source's.
    public func search(_ query: String, in scope: SearchScope, limit: Int? = nil) async throws -> [SearchResultSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TextMatcher(query: trimmed).isEmpty else { return [] }
        let sources = sources
        let hits = try await store.read { tx in
            try sources.flatMap { try $0.search(trimmed, in: scope, limit: limit, tx: tx) }
        }
        return Dictionary(grouping: hits, by: \.group)
            .map { SearchResultSection(group: $0.key, hits: $0.value) }
            .sorted { $0.group.order < $1.group.order }
    }

    /// A book-text hit's match pinned by its words and context, as the engines resolve it: made
    /// when a hit is chosen rather than for every hit, from the indexed text of its chunk. Nil when
    /// the hit has no range or its chunk is gone.
    public func anchor(in documentID: DocumentID, chunk: Locator?, match: Range<Int>?) async throws -> QuoteAnchor? {
        guard let chunk, let match else { return nil }
        return try await store.read { tx in
            guard let entry = try tx.fullText.entries(corpus: .bookText, documentID: documentID).first(where: { $0.locator == chunk }),
                  match.upperBound <= entry.body.utf16.count else { return nil }
            return QuoteAnchor(range: match, in: entry.body)
        }
    }
}

// MARK: Standard sources

/// Notes pages (titles and bodies) in one book or all books.
public struct NotesSearchSource: SearchSource {
    public init() {}

    public func search(_ query: String, in scope: SearchScope, limit: Int?, tx: any ReadTransaction) throws -> [SearchHit] {
        let documentID: DocumentID?
        switch scope {
        case .allNotes: documentID = nil
        case .document(let id, let facets) where facets.contains(.notes): documentID = id
        default: return []
        }
        let matcher = TextMatcher(query: query)
        let hits = try tx.fullText.search(FullTextQuery(text: query, corpus: .notes, documentID: documentID, limit: limit.map { $0 * 2 }))
        return try hits.compactMap { hit -> SearchHit? in
            guard let pageID = PageID(hit.owner), let page = try tx.pages.page(pageID), page.trash == nil,
                  let document = try tx.documents.document(page.documentID), document.trash == nil else { return nil }
            let match = NotesSearchSource.firstVisibleMatch(of: matcher, in: page.body)
            let title = page.title.isEmpty ? PageService.untitled : page.title
            // Across books, name the book, unless the title already does (a book's main page).
            let subtitle = documentID == nil && title != document.title ? document.title : nil
            return SearchHit(group: .notes, title: title, subtitle: subtitle, snippet: hit.snippet,
                             destination: .page(page.id, page.documentID, match: match))
        }.prefix(limit ?? .max).map { $0 }
    }

    /// The first match in the raw body that is not inside link syntax (so `gloss://` ids never
    /// count as hits).
    static func firstVisibleMatch(of matcher: TextMatcher, in body: String) -> Range<Int>? {
        let document = MarkdownParser.standard.parse(body)
        let hidden = document.allInlines.flatMap(\.syntax)
        for range in matcher.matchRanges(in: body) {
            let lower = body.utf16.distance(from: body.startIndex, to: range.lowerBound)
            let upper = body.utf16.distance(from: body.startIndex, to: range.upperBound)
            if !hidden.contains(where: { $0.contains(lower) }) { return lower..<upper }
        }
        return nil
    }
}

/// Every match in a book's extracted text, in reading order, matched as the readers highlight
/// (`BookTextMatcher`). The index is only read for its text here: its ranked search returns one
/// hit per chunk (a whole chapter), best chunks first, which is no way to find in a book.
public struct BookTextSearchSource: SearchSource {
    public init() {}

    public func search(_ query: String, in scope: SearchScope, limit: Int?, tx: any ReadTransaction) throws -> [SearchHit] {
        guard case .document(let id, let facets) = scope, facets.contains(.text) else { return [] }
        guard let document = try tx.documents.document(id), document.trash == nil else { return [] }
        let matcher = BookTextMatcher(query: query)
        guard !matcher.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for chunk in try tx.fullText.entries(corpus: .bookText, documentID: id) {
            let ranges = matcher.ranges(in: chunk.body)
            guard !ranges.isEmpty else { continue }
            let units = Array(chunk.body.utf16)
            let title = chunk.label ?? document.title
            for range in ranges {
                if let limit, hits.count >= limit { return hits }
                let snippet = Snippet.excerpt(around: range, in: units)
                let matchText = snippet.segments.first(where: \.isMatch)?.text ?? ""
                hits.append(SearchHit(group: .bookText, title: title, subtitle: nil, snippet: snippet,
                                      destination: .bookText(id, locator: chunk.locator, matchText: matchText, match: range)))
            }
        }
        return hits
    }
}

/// Titles and authors.
public struct LibrarySearchSource: SearchSource {
    public init() {}

    public func search(_ query: String, in scope: SearchScope, limit: Int?, tx: any ReadTransaction) throws -> [SearchHit] {
        guard scope == .library else { return [] }
        return try tx.fullText.search(FullTextQuery(text: query, corpus: .library, limit: limit.map { $0 * 2 })).compactMap { hit in
            guard let id = DocumentID(hit.owner), let document = try tx.documents.document(id), document.trash == nil else { return nil }
            return SearchHit(group: .library, title: document.title, subtitle: document.author.isEmpty ? nil : document.author,
                             snippet: hit.snippet, destination: .document(id))
        }.prefix(limit ?? .max).map { $0 }
    }
}
