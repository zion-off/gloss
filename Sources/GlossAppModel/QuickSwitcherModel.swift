import Foundation
import Observation
import GlossCore

/// ⌘O: jump to a book or a notes page by typing.
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

    private let services: GlossServices

    public init(services: GlossServices) {
        self.services = services
    }

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
        if let notes = try? await services.search.search(trimmed, in: .allNotes, limit: 8) {
            for hit in notes.flatMap(\.hits) {
                guard case .page(let pageID, let documentID, _) = hit.destination else { continue }
                found.append(Item(kind: .page, title: hit.title, subtitle: hit.subtitle, documentID: documentID, pageID: pageID))
            }
        }
        items = Array(found.prefix(12))
    }
}
