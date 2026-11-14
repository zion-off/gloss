/// What part of a book a document scope covers.
public enum SearchFacet: String, Hashable, Codable, Sendable, CaseIterable {
    case text, notes
}

/// What to search. Semantic, so sources decide for themselves whether they take part.
public enum SearchScope: Hashable, Sendable {
    case library
    case allNotes
    case document(DocumentID, Set<SearchFacet>)
}

extension SearchScope {
    /// Whether this scope searches the text of this book.
    public func coversText(of documentID: DocumentID) -> Bool {
        if case .document(let id, let facets) = self { return id == documentID && facets.contains(.text) }
        return false
    }

    /// Whether this scope searches the notes of this book (all notes covers every book's).
    public func coversNotes(of documentID: DocumentID) -> Bool {
        switch self {
        case .allNotes: true
        case .document(let id, let facets): id == documentID && facets.contains(.notes)
        default: false
        }
    }
}

/// Where the user is when they start typing in the search field.
public enum SearchContext: Hashable, Sendable {
    case home
    case reader(DocumentID)
    case notes(DocumentID)
    case split(DocumentID)
}

/// One entry in the search field's scope menu.
public struct SearchScopeOption: Hashable, Sendable, Identifiable {
    public var scope: SearchScope
    public var title: String
    public var id: String { title }
}

/// Derives the scope menu (default first) from the context.
public enum SearchScopeResolver {
    public static func options(for context: SearchContext) -> [SearchScopeOption] {
        let library = SearchScopeOption(scope: .library, title: "library")
        let allNotes = SearchScopeOption(scope: .allNotes, title: "all notes")
        func text(_ id: DocumentID) -> SearchScopeOption { .init(scope: .document(id, [.text]), title: "this book's text") }
        func notes(_ id: DocumentID) -> SearchScopeOption { .init(scope: .document(id, [.notes]), title: "this book's notes") }
        switch context {
        case .home:
            return [library, allNotes]
        case .reader(let id):
            return [text(id), notes(id), allNotes, library]
        case .notes(let id):
            return [notes(id), text(id), allNotes, library]
        case .split(let id):
            return [.init(scope: .document(id, [.text, .notes]), title: "this book"), text(id), notes(id), allNotes, library]
        }
    }

    public static func defaultScope(for context: SearchContext) -> SearchScope {
        options(for: context)[0].scope
    }
}
