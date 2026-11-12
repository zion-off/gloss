import Foundation
import Testing
@testable import GlossCore
import GlossTestSupport

@Suite("search")
struct SearchTests {
    let id = DocumentID(GlossID(high: 0x7000, low: 77))

    @Test("scope options follow the context, default first")
    func scopes() {
        #expect(SearchScopeResolver.options(for: .home).map(\.title) == ["library", "all notes"])
        #expect(SearchScopeResolver.options(for: .reader(id)).map(\.title) == ["this book's text", "this book's notes", "all notes", "library"])
        #expect(SearchScopeResolver.options(for: .notes(id)).map(\.title) == ["this book's notes", "this book's text", "all notes", "library"])
        #expect(SearchScopeResolver.defaultScope(for: .split(id)) == .document(id, [.text, .notes]))
    }

    @Test("split view's default scope returns notes and book text, notes first")
    func grouped() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book(chapters: ["the plague came to oran"])
        try await lib.services.pages.updateBody(root.id, to: "oran feels like a character")
        let sections = try await lib.services.search.search("oran", in: SearchScopeResolver.defaultScope(for: .split(document.id)))
        #expect(sections.map(\.group) == [.notes, .bookText])
        #expect(sections[0].hits[0].destination == .page(root.id, document.id, match: 0..<4))
    }

    @Test("page hits skip matches inside link destinations")
    func hiddenMatches() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book()
        let target = try await lib.services.links.target(for: lib.passage("q", at: "c"), in: document.id)
        try await lib.services.pages.updateBody(root.id, to: "[link](gloss://passage/\(target.id)) then gloss appears")
        let hit = try await lib.services.search.search("gloss", in: .allNotes).first?.hits.first
        #expect(hit?.destination == .page(root.id, document.id, match: 56..<61))
        #expect(try await lib.services.search.search("passage", in: .allNotes).isEmpty)
    }

    @Test("all notes spans books and names them; trashed things are hidden")
    func allNotes() async throws {
        let lib = TestLibrary()
        let (a, aRoot) = try await lib.book("A")
        let (_, bRoot) = try await lib.book("B")
        try await lib.services.pages.updateBody(aRoot.id, to: "lighthouse")
        let sub = try await lib.services.pages.createSubpage(under: bRoot.id, title: "keeper")
        try await lib.services.pages.updateBody(sub.id, to: "lighthouse keeper")
        let hits = try #require(try await lib.services.search.search("lighthouse", in: .allNotes).first?.hits)
        // A book's main page is titled after the book, so only the subpage names its book.
        #expect(Set(hits.map { "\($0.title)|\($0.subtitle ?? "-")" }) == ["A|-", "keeper|B"])
        _ = try await lib.services.trash.trash(.document, id: a.id.stringValue)
        #expect(try await lib.services.search.search("lighthouse", in: .allNotes).first?.hits.map(\.title) == ["keeper"])
        #expect(try await lib.services.search.search("   ", in: .allNotes).isEmpty)
    }

    @Test("custom sources join in")
    func customSource() async throws {
        struct Echo: SearchSource {
            func search(_ query: String, in scope: SearchScope, limit: Int, tx: any ReadTransaction) throws -> [SearchHit] {
                [SearchHit(group: SearchResultGroup(id: "echo", title: "echo", order: -1), title: query, subtitle: nil,
                           snippet: Snippet(segments: []), destination: .document(DocumentID(GlossID(high: 0, low: 0))))]
            }
        }
        let lib = TestLibrary()
        let service = SearchService(store: lib.store, sources: SearchService.standardSources + [Echo()])
        #expect(try await service.search("hello", in: .library).first?.group.id == "echo")
    }

    @Test("note snippets read as text, without markdown markers")
    func cleanSnippets() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        try await lib.services.pages.updateBody(root.id, to: "- [x] finish part one\n> mother died **today**")
        let snippet = try #require(try await lib.services.search.search("mother", in: .allNotes).first?.hits.first?.snippet.plainText)
        #expect(!snippet.contains("[x]") && !snippet.contains(">") && !snippet.contains("**"))
        #expect(snippet.contains("mother died today"))
    }

    @Test("rebuilding derived data restores indexes and references")
    func rebuild() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book(chapters: ["stranger"])
        let (_, target, _) = try await lib.services.links.addQuote(of: lib.passage("q", at: "c"), in: document.id, to: root.id)
        try await lib.store.write { tx in
            try tx.references.removeAllReferences()
            try tx.fullText.removeAllEntries(corpus: .notes)
            try tx.fullText.removeAllEntries(corpus: .bookText)
        }
        #expect(try await lib.services.links.linkedPassages(in: document.id).isEmpty)
        let report = try await lib.services.rebuilder.rebuildAll()
        #expect(report.textChunks == 1)
        #expect(try await lib.services.links.linkedPassages(in: document.id).map(\.target.id) == [target.id])
        #expect(try await lib.services.search.search("stranger", in: .document(document.id, [.text])).count == 1)
    }
}
