import Foundation
import GlossCore

/// Turns what the user typed into a book, page or trash entry. Accepted, in order:
/// a `gloss://` link, a full id, an id fragment of 4+ characters (its start or its end — the
/// short ids gloss prints are id endings), then a title (case- and accent-insensitive, exact
/// before partial). Ambiguity is an error that lists the candidates.
struct References: Sendable {
    let services: GlossServices
    let printer: Printer

    // MARK: Books

    func document(_ ref: String) async throws -> Document {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIFailure("which book? give a title, an id or a gloss:// link", code: CLIFailure.usageCode) }
        return try await services.store.read { tx in
            let all = try tx.documents.documents(.any)
            if let link = GlossLink(string: trimmed) {
                switch link {
                case .document(let id):
                    return try Self.live(try tx.documents.document(id), what: "that book")
                case .page(let id):
                    guard let page = try tx.pages.page(id) else { throw CLIFailure("couldn't find that page") }
                    return try Self.live(try tx.documents.document(page.documentID), what: "that book")
                case .passage(let id):
                    guard let target = try tx.linkTargets.linkTarget(id) else { throw CLIFailure("couldn't find that passage") }
                    return try Self.live(try tx.documents.document(target.documentID), what: "that book")
                }
            }
            if let id = DocumentID(trimmed), let exact = all.first(where: { $0.id == id }) {
                return try Self.live(exact, what: exact.title)
            }
            // A page's id names its book, like a gloss://page link does.
            if let raw = GlossID(string: trimmed), let page = try tx.pages.page(PageID(raw)) {
                return try Self.live(try tx.documents.document(page.documentID), what: "that book")
            }
            let live = all.filter { $0.trash == nil }
            // An exact title beats an id fragment: titles like "decaf" are valid base32.
            let exactTitles = Self.exactTitleMatches(live, title: \.title, query: trimmed)
            if exactTitles.count == 1 { return exactTitles[0] }
            let byFragment = exactTitles.isEmpty ? all.filter { Self.matchesFragment($0.id.stringValue, trimmed) } : []
            if byFragment.count == 1 { return try Self.live(byFragment[0], what: byFragment[0].title) }
            let matches = Self.titleMatches(live, title: \.title, query: trimmed)
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 || byFragment.count > 1 {
                let candidates = matches.count > 1 ? matches : byFragment
                throw CLIFailure("“\(trimmed)” matches more than one book",
                                 hint: Self.candidateList(candidates.map { (Format.shortID($0.id), $0.title, $0.author) }) + "\nuse an id to pick one")
            }
            if let trashed = Self.titleMatches(all.filter { $0.trash != nil }, title: \.title, query: trimmed).first {
                throw CLIFailure("\(trashed.title) is in the trash", hint: "bring it back with: gloss trash restore \"\(trashed.title)\"")
            }
            throw CLIFailure("couldn't find a book called “\(trimmed)”", hint: "see what's there with: gloss list", notFound: true)
        }
    }

    // MARK: Pages

    /// A page; a book reference means that book's main notes page.
    func page(_ ref: String) async throws -> Page {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIFailure("which page? give a title, an id or a gloss:// link", code: CLIFailure.usageCode) }
        let result: Page? = try await services.store.read { tx in
            if let link = GlossLink(string: trimmed) {
                switch link {
                case .page(let id): return try Self.livePage(try tx.pages.page(id))
                case .document(let id):
                    _ = try Self.live(try tx.documents.document(id), what: "that book")
                    return try tx.pages.rootPage(of: id)
                case .passage:
                    throw CLIFailure("that's a passage link, not a page", hint: "open it with: gloss open \(trimmed)")
                }
            }
            if let raw = GlossID(string: trimmed) {
                if let page = try tx.pages.page(PageID(raw)) { return try Self.livePage(page) }
                if let document = try tx.documents.document(DocumentID(raw)) {
                    _ = try Self.live(document, what: document.title)
                    return try tx.pages.rootPage(of: document.id)
                }
            }
            let pages = try tx.pages.pages(.any)
            let documents = try tx.documents.documents(.any)
            let livePages = pages.filter { $0.trash == nil }
            let liveDocuments = documents.filter { $0.trash == nil }
            let pageTitle: (Page) -> String = { $0.title.isEmpty ? PageService.untitled : $0.title }
            let titles = Dictionary(documents.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            // An exact title beats an id fragment: titles like "decaf" are valid base32.
            let hasExactTitle = !Self.exactTitleMatches(livePages, title: pageTitle, query: trimmed).isEmpty
                || !Self.exactTitleMatches(liveDocuments, title: \.title, query: trimmed).isEmpty
            if !hasExactTitle {
                let pageFragments = pages.filter { Self.matchesFragment($0.id.stringValue, trimmed) }
                let documentFragments = documents.filter { Self.matchesFragment($0.id.stringValue, trimmed) }
                if pageFragments.count + documentFragments.count == 1 {
                    if let page = pageFragments.first { return try Self.livePage(page) }
                    let document = try Self.live(documentFragments[0], what: documentFragments[0].title)
                    return try tx.pages.rootPage(of: document.id)
                }
                if pageFragments.count + documentFragments.count > 1 {
                    let rows: [(id: String, title: String, detail: String)] =
                        pageFragments.map { (Format.shortID($0.id), pageTitle($0), titles[$0.documentID] ?? "") }
                        + documentFragments.map { (Format.shortID($0.id), $0.title, "book") }
                    throw CLIFailure("“\(trimmed)” matches more than one thing", hint: Self.candidateList(rows) + "\nuse a longer id to pick one")
                }
            }
            let titled = Self.titleMatches(livePages, title: pageTitle, query: trimmed)
            // A book title means its main page, unless a subpage has exactly that title.
            let books = Self.titleMatches(liveDocuments, title: \.title, query: trimmed)
            if titled.count == 1, books.isEmpty || titled[0].parentID != nil { return titled[0] }
            if titled.count <= 1, books.count == 1 { return try tx.pages.rootPage(of: books[0].id) }
            if titled.count > 1 {
                throw CLIFailure("“\(trimmed)” matches more than one page",
                                 hint: Self.candidateList(titled.map { (Format.shortID($0.id), $0.title, titles[$0.documentID] ?? "") }) + "\nuse an id to pick one")
            }
            return nil
        }
        guard let result else {
            throw CLIFailure("couldn't find a page called “\(trimmed)”", hint: "list a book's pages with: gloss pages <book>", notFound: true)
        }
        return result
    }

    // MARK: Trash entries

    func trashEntry(_ ref: String) async throws -> TrashEntry {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = try await services.trash.entries()
        if let id = TrashEntryID(trimmed), let exact = entries.first(where: { $0.id == id }) { return exact }
        let fragments = entries.filter { Self.matchesFragment($0.id.stringValue, trimmed) }
        if fragments.count == 1 { return fragments[0] }
        let titled = Self.titleMatches(entries, title: \.title, query: trimmed)
        if titled.count == 1 { return titled[0] }
        let candidates = titled.count > 1 ? titled : fragments
        if candidates.count > 1 {
            throw CLIFailure("“\(trimmed)” matches more than one thing in the trash",
                             hint: Self.candidateList(candidates.map { (Format.shortID($0.id), $0.title, $0.kind.rawValue) }) + "\nuse an id to pick one")
        }
        throw CLIFailure("nothing in the trash matches “\(trimmed)”", hint: "see what's there with: gloss trash list")
    }

    // MARK: Matching

    static func matchesFragment(_ id: String, _ fragment: String) -> Bool {
        let lower = fragment.lowercased()
        guard lower.count >= 4, lower.count < 26, lower.allSatisfy({ "0123456789abcdefghjkmnpqrstvwxyz".contains($0) }) else { return false }
        return id.hasPrefix(lower) || id.hasSuffix(lower)
    }

    /// Exact (folded) title matches only.
    static func exactTitleMatches<T>(_ items: [T], title: (T) -> String, query: String) -> [T] {
        let folded = TextMatcher.fold(query.trimmingCharacters(in: .whitespaces))
        guard !folded.isEmpty else { return [] }
        return items.filter { TextMatcher.fold(title($0)) == folded }
    }

    /// Exact (folded) title matches, or else partial ones.
    static func titleMatches<T>(_ items: [T], title: (T) -> String, query: String) -> [T] {
        let folded = TextMatcher.fold(query.trimmingCharacters(in: .whitespaces))
        guard !folded.isEmpty else { return [] }
        let exact = items.filter { TextMatcher.fold(title($0)) == folded }
        if !exact.isEmpty { return exact }
        return items.filter { TextMatcher.fold(title($0)).contains(folded) }
    }

    static func candidateList(_ rows: [(id: String, title: String, detail: String)]) -> String {
        rows.prefix(8).map { "\($0.id)  \($0.title)" + ($0.detail.isEmpty ? "" : "  · \($0.detail)") }.joined(separator: "\n")
            + (rows.count > 8 ? "\n…and \(rows.count - 8) more" : "")
    }

    static func live(_ document: Document?, what: String) throws -> Document {
        guard let document else { throw CLIFailure("couldn't find \(what)", notFound: true) }
        guard document.trash == nil else {
            throw CLIFailure("\(document.title) is in the trash", hint: "bring it back with: gloss trash restore \"\(document.title)\"")
        }
        return document
    }

    static func livePage(_ page: Page?) throws -> Page {
        guard let page else { throw CLIFailure("couldn't find that page", notFound: true) }
        guard page.trash == nil else {
            let title = page.title.isEmpty ? PageService.untitled : page.title
            throw CLIFailure("\(title) is in the trash", hint: "bring it back with: gloss trash restore \"\(title)\"")
        }
        return page
    }
}
