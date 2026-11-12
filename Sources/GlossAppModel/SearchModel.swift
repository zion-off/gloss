import Foundation
import Observation
import GlossCore

/// The search popover's state: query, scope (derived from context), grouped results.
@MainActor @Observable public final class SearchModel {
    public var query = "" {
        didSet { guard query != oldValue else { return }; scheduleSearch() }
    }
    public private(set) var scope: SearchScope
    public private(set) var results: [SearchResultSection] = []
    public private(set) var isSearching = false

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
            self?.isSearching = false
        }
    }

    /// Waits for the search started by the latest query or scope change.
    public func settle() async {
        await searchTask?.value
    }

    public func cancel() {
        searchTask?.cancel()
        results = []
        isSearching = false
    }
}
