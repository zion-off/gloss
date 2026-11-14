import Foundation

/// A named body of searchable text. Open: a new search source adds a corpus and an indexer,
/// never a schema change.
public struct Corpus: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let notes = Corpus("notes")
    public static let bookText = Corpus("book-text")
    public static let library = Corpus("library")
}

/// One indexed chunk of text.
public struct FullTextEntry: Hashable, Sendable {
    public var corpus: Corpus
    /// The entity that owns the chunk (a page id, a document id, …). Re-indexing an owner
    /// replaces all of its chunks.
    public var owner: String
    public var documentID: DocumentID?
    public var locator: Locator?
    public var label: String?
    public var title: String
    public var body: String

    public init(corpus: Corpus, owner: String, documentID: DocumentID?, locator: Locator? = nil,
                label: String? = nil, title: String, body: String) {
        self.corpus = corpus
        self.owner = owner
        self.documentID = documentID
        self.locator = locator
        self.label = label
        self.title = title
        self.body = body
    }
}

public struct FullTextQuery: Hashable, Sendable {
    public var text: String
    public var corpus: Corpus
    public var documentID: DocumentID?
    public var limit: Int

    public init(text: String, corpus: Corpus, documentID: DocumentID? = nil, limit: Int = 50) {
        self.text = text
        self.corpus = corpus
        self.documentID = documentID
        self.limit = limit
    }
}

/// A short excerpt around a hit, split into plain and matching segments.
public struct Snippet: Hashable, Codable, Sendable {
    public struct Segment: Hashable, Codable, Sendable {
        public var text: String
        public var isMatch: Bool
        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    public var segments: [Segment]
    public init(segments: [Segment]) { self.segments = segments }

    public var plainText: String { segments.map(\.text).joined() }
}

public struct FullTextHit: Hashable, Sendable {
    public var corpus: Corpus
    public var owner: String
    public var documentID: DocumentID?
    public var locator: Locator?
    public var label: String?
    public var title: String
    public var snippet: Snippet
    /// Lower is better.
    public var rank: Double

    public init(corpus: Corpus, owner: String, documentID: DocumentID?, locator: Locator?, label: String?,
                title: String, snippet: Snippet, rank: Double) {
        self.corpus = corpus
        self.owner = owner
        self.documentID = documentID
        self.locator = locator
        self.label = label
        self.title = title
        self.snippet = snippet
        self.rank = rank
    }
}

public protocol FullTextSearching {
    func search(_ query: FullTextQuery) throws -> [FullTextHit]
}

public protocol FullTextIndexing: FullTextSearching {
    func replaceEntries(_ entries: [FullTextEntry], corpus: Corpus, owner: String) throws
    func removeEntries(corpus: Corpus, owner: String) throws
    func removeEntries(corpus: Corpus, documentID: DocumentID) throws
    func removeAllEntries(corpus: Corpus) throws
}
