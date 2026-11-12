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
    /// A place in the book; the engine finds and highlights `matchText` near `locator`.
    case bookText(DocumentID, locator: Locator?, matchText: String)
}

public struct SearchHit: Hashable, Sendable {
    public var group: SearchResultGroup
    public var title: String
    public var subtitle: String?
    public var snippet: Snippet
    public var destination: SearchDestination
}

public struct SearchResultSection: Hashable, Sendable, Identifiable {
    public var group: SearchResultGroup
    public var hits: [SearchHit]
    public var id: String { group.id }
}

/// A searchable source. Register one to make something new searchable.
public protocol SearchSource: Sendable {
    /// Hits for `query` within `scope`, or none if the source does not cover that scope.
    func search(_ query: String, in scope: SearchScope, limit: Int, tx: any ReadTransaction) throws -> [SearchHit]
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

    public func search(_ query: String, in scope: SearchScope, limit: Int = 30) async throws -> [SearchResultSection] {
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
}

// MARK: Standard sources

/// Notes pages (titles and bodies) in one book or all books.
public struct NotesSearchSource: SearchSource {
    public init() {}

    public func search(_ query: String, in scope: SearchScope, limit: Int, tx: any ReadTransaction) throws -> [SearchHit] {
        let documentID: DocumentID?
        switch scope {
        case .allNotes: documentID = nil
        case .document(let id, let facets) where facets.contains(.notes): documentID = id
        default: return []
        }
        let matcher = TextMatcher(query: query)
        let hits = try tx.fullText.search(FullTextQuery(text: query, corpus: .notes, documentID: documentID, limit: limit * 2))
        return try hits.compactMap { hit -> SearchHit? in
            guard let pageID = PageID(hit.owner), let page = try tx.pages.page(pageID), page.trash == nil,
                  let document = try tx.documents.document(page.documentID), document.trash == nil else { return nil }
            let match = NotesSearchSource.firstVisibleMatch(of: matcher, in: page.body)
            return SearchHit(group: .notes, title: page.title.isEmpty ? PageService.untitled : page.title,
                             subtitle: documentID == nil ? document.title : nil, snippet: hit.snippet,
                             destination: .page(page.id, page.documentID, match: match))
        }.prefix(limit).map { $0 }
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

/// Extracted book text.
public struct BookTextSearchSource: SearchSource {
    public init() {}

    public func search(_ query: String, in scope: SearchScope, limit: Int, tx: any ReadTransaction) throws -> [SearchHit] {
        guard case .document(let id, let facets) = scope, facets.contains(.text) else { return [] }
        guard let document = try tx.documents.document(id), document.trash == nil else { return [] }
        let matcher = TextMatcher(query: query)
        return try tx.fullText.search(FullTextQuery(text: query, corpus: .bookText, documentID: id, limit: limit)).map { hit in
            let matchText = hit.snippet.segments.first(where: \.isMatch)?.text ?? matcher.tokens.first ?? query
            return SearchHit(group: .bookText, title: hit.label ?? document.title, subtitle: nil, snippet: hit.snippet,
                             destination: .bookText(id, locator: hit.locator, matchText: matchText))
        }
    }
}

/// Titles and authors.
public struct LibrarySearchSource: SearchSource {
    public init() {}

    public func search(_ query: String, in scope: SearchScope, limit: Int, tx: any ReadTransaction) throws -> [SearchHit] {
        guard scope == .library else { return [] }
        return try tx.fullText.search(FullTextQuery(text: query, corpus: .library, limit: limit * 2)).compactMap { hit in
            guard let id = DocumentID(hit.owner), let document = try tx.documents.document(id), document.trash == nil else { return nil }
            return SearchHit(group: .library, title: document.title, subtitle: document.author.isEmpty ? nil : document.author,
                             snippet: hit.snippet, destination: .document(id))
        }.prefix(limit).map { $0 }
    }
}
