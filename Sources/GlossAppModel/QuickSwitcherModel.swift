import Foundation
import Observation
import GlossCore

/// "open quickly" (⇧⌘O, after Xcode): jump to a book or a notes page by typing (D-071).
@MainActor @Observable public final class QuickSwitcherModel {
    public struct Item: Hashable, Identifiable, Sendable {
        public enum Kind: Hashable, Sendable { case document, page }
        public var id = UUID()
        public var kind: Kind
        public var title: String
        public var subtitle: String?
        public var documentID: DocumentID
        public var pageID: PageID?

        public var isPage: Bool { kind == .page }
    }

    public private(set) var items: [Item] = []
    /// What the field holds. Typing is debounced into `search`, so a query per keystroke
    /// never holds the field back.
    public var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }
    /// The row the keyboard has picked; Return opens it.
    public private(set) var selectedIndex = 0

    private let services: GlossServices
    private var searchTask: Task<Void, Never>?

    public init(services: GlossServices) {
        self.services = services
    }

    /// The row Return would open.
    public var selected: Item? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    /// Moves the keyboard selection, wrapping around like Xcode's switcher.
    public func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    /// Runs the query now (the debounced task calls this; tests can too).
    public func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TextMatcher(query: trimmed).isEmpty else {
            items = []
            return
        }
        var found: [Item] = []
        if let books = try? await services.search.search(trimmed, in: .library, limit: 5) {
            for hit in books.flatMap(\.hits) {
                guard case .document(let id) = hit.destination else { continue }
                found.append(Item(kind: .document, title: hit.title, subtitle: hit.subtitle, documentID: id, pageID: nil))
            }
        }
        // A newer keystroke may have cancelled this query while it read (review 7): a stale
        // result must never overwrite the newest one.
        guard !Task.isCancelled else { return }
        if let notes = try? await services.search.search(trimmed, in: .allNotes, limit: 8) {
            for hit in notes.flatMap(\.hits) {
                guard case .page(let pageID, let documentID, _) = hit.destination else { continue }
                found.append(Item(kind: .page, title: hit.title, subtitle: hit.subtitle, documentID: documentID, pageID: pageID))
            }
        }
        guard !Task.isCancelled else { return }
        items = Array(found.prefix(12))
        selectedIndex = 0
    }

    /// Debounces typing into one search per pause.
    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TextMatcher(query: trimmed).isEmpty else {
            searchTask = nil
            items = []
            selectedIndex = 0
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            await self.search(trimmed)
        }
    }

    /// Waits for the search the latest keystroke started.
    public func settle() async {
        while let task = searchTask {
            await task.value
            if searchTask == task { break }
        }
    }

    /// Clears the field and the results (the sheet closed, or is about to open again).
    public func reset() {
        searchTask?.cancel()
        searchTask = nil
        query = ""  // the didSet clears the results
    }
}
