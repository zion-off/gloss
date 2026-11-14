import Foundation
import Observation
import GlossCore

/// The search field's state: query, scope (derived from context), grouped results, and the
/// session the query opens: the results also exist as one stepping list, and while a query
/// stands they show in the sidebar inside a book (the main pane keeps the book) and in the
/// main pane on the library.
@MainActor @Observable public final class SearchModel {
    public var query = "" {
        didSet { guard query != oldValue else { return }; scheduleSearch() }
    }
    public private(set) var scope: SearchScope
    public private(set) var results: [SearchResultSection] = []
    public private(set) var isSearching = false
    /// The session's stepping list: the results flattened in display order, the current one,
    /// wraparound. Lives while a query stands.
    public private(set) var stepper = SearchStepper()
    /// The book the session searches: the one it started in, or the one a result opened.
    /// Switching to another book any other way ends the session.
    public private(set) var sessionDocumentID: DocumentID?

    /// Selecting a hit tells the workspace (and the editor/engine) where to go.
    public enum Selection: Hashable, Sendable {
        case page(PageID, DocumentID, match: Range<Int>?)
        case bookText(DocumentID, locator: Locator?, matchText: String)
        case document(DocumentID)
    }

    public struct Hit: Hashable, Identifiable, Sendable {
        public var id = UUID()
        public var hit: SearchHit
        public var section: String

        public init(hit: SearchHit, section: String) {
            self.hit = hit
            self.section = section
        }

        public var selection: Selection {
            switch hit.destination {
            case .page(let page, let document, let match): return .page(page, document, match: match)
            case .bookText(let document, let locator, let matchText): return .bookText(document, locator: locator, matchText: matchText)
            case .document(let document): return .document(document)
            }
        }
    }

    private let services: GlossServices
    private let contextProvider: @MainActor () -> SearchContext
    private var searchTask: Task<Void, Never>?

    public init(services: GlossServices, contextProvider: @escaping @MainActor () -> SearchContext) {
        self.services = services
        self.contextProvider = contextProvider
        self.scope = SearchScopeResolver.defaultScope(for: contextProvider())
    }

    /// The scope menu for the current context, default first.
    public var scopeOptions: [SearchScopeOption] {
        SearchScopeResolver.options(for: contextProvider())
    }

    public func setScope(_ scope: SearchScope) {
        self.scope = scope
        scheduleSearch()
    }

    /// Fixes a scope that the new context no longer offers (external changes, restores).
    public func contextChanged() {
        let options = scopeOptions
        if !options.contains(where: { $0.scope == scope }) {
            scope = options.first?.scope ?? .library
            scheduleSearch()
        }
    }

    /// Adopts the default scope of the current context (the user opened another book).
    public func resetToDefaultScope() {
        let next = scopeOptions.first?.scope ?? .library
        guard next != scope else { return }
        scope = next
        scheduleSearch()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TextMatcher(query: trimmed).isEmpty else {
            results = []
            stepper = SearchStepper()
            isSearching = false
            return
        }
        let scope = scope
        isSearching = true
        searchTask = Task { [weak self] in
            // Small debounce so typing doesn't fire a query per character.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = (try? await self?.services.search.search(trimmed, in: scope)) ?? []
            guard !Task.isCancelled else { return }
            self?.results = found
            self?.stepper.replace(sections: found)
            self?.isSearching = false
        }
    }

    /// Waits for the search started by the latest query or scope change.
    public func settle() async {
        while let task = searchTask {
            await task.value
            if searchTask == task { break }
        }
    }

    /// Where the results show, from where the user is: the sidebar inside a book (the book or
    /// notes stay in the main pane beside it), the main pane on the library.
    public var showsResultsInSidebar: Bool {
        showsResults && contextProvider() != .home
    }

    /// Whether the results fill the main pane (no book is open: the library, the trash).
    public var showsResultsInMainPane: Bool {
        showsResults && contextProvider() == .home
    }

    /// Find Next/Previous (⌘G, ⇧⌘G): steps with wraparound and returns the hit it lands on.
    public func step(by delta: Int) -> SearchHit? {
        stepper.step(by: delta)
    }

    /// A click or a list selection: makes this result current and returns it.
    public func selectResult(at index: Int) -> SearchHit? {
        stepper.select(at: index)
    }

    /// The flat index of a hit, for the row that shows it (nil when it isn't in the list).
    public func index(of hit: SearchHit) -> Int? {
        stepper.index(of: hit)
    }

    /// The session follows where the user went: it keeps the book it started in, or the one a
    /// result opened (`sessionMoves`); switching books any other way ends it. Without a query
    /// there is no session. Returns whether the session ended.
    @discardableResult
    public func followContextChange(currentDocument: DocumentID?) -> Bool {
        guard hasQuery else {
            sessionDocumentID = nil
            return false
        }
        if sessionDocumentID == nil {
            sessionDocumentID = currentDocument
            return false
        }
        if sessionDocumentID != currentDocument {
            dismiss()
            return true
        }
        return false
    }

    /// A result opened this book: the session moves with it.
    public func sessionMoves(to documentID: DocumentID?) {
        sessionDocumentID = documentID
    }

    public func cancel() {
        searchTask?.cancel()
        results = []
        stepper = SearchStepper()
        isSearching = false
    }

    /// Whether the field holds a query worth showing results for.
    public var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The book the current context is in, nil on the library.
    private var contextDocumentID: DocumentID? {
        switch contextProvider() {
        case .home: nil
        case .reader(let id), .notes(let id), .split(let id): id
        }
    }

    /// Whether the search field is open (focused or expanded); the window binds it to the field.
    public var isPresented = false

    /// Whether the results pane replaces the detail column: while the search is open, even with
    /// the field cleared (an empty search state, not a jump home), or while a query stands after
    /// the field lost focus.
    public var showsResults: Bool { isPresented || hasQuery }

    /// The current scope's name, for the empty search state ("this book", "everything").
    public var scopeTitle: String? {
        scopeOptions.first { $0.scope == scope }?.title
    }

    /// A result was chosen (or the user gave up): clear the field, the results and any search
    /// still in flight, and close the search, so the detail column returns to where the hit goes.
    public func dismiss() {
        query = ""  // the didSet clears the results
        isPresented = false
        sessionDocumentID = nil
        cancel()
    }
}
