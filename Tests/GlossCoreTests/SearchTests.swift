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
            func search(_ query: String, in scope: SearchScope, limit: Int?, tx: any ReadTransaction) throws -> [SearchHit] {
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

    @Test("in-book search lists every match, in reading order, however many")
    func everyMatchInOrder() async throws {
        let lib = TestLibrary()
        let many = Array(repeating: "whale", count: 40).joined(separator: " and ")
        let (document, _) = try await lib.book(chapters: ["the whale, then another whale", "no match here", many, "a last whale"])
        let hits = try await lib.services.search.search("whale", in: .document(document.id, [.text])).flatMap(\.hits)
        #expect(hits.count == 2 + 40 + 1)
        #expect(hits.map(\.title) == ["chapter 1", "chapter 1"] + Array(repeating: "chapter 3", count: 40) + ["chapter 4"])
        // Within a chapter, each match is its own place, in order.
        let starts = hits.compactMap { hit -> Int? in
            guard case .bookText(_, _, _, let match) = hit.destination else { return nil }
            return match?.lowerBound
        }
        #expect(Array(starts[0..<2]) == [4, 24])
        #expect(Array(starts[2..<42]) == (0..<40).map { $0 * 10 })  // "whale and " is 10 long
        #expect(starts[42] == 7)
        // A caller that asks for a limit (the cli) gets the first matches in reading order.
        let first = try await lib.services.search.search("whale", in: .document(document.id, [.text]), limit: 3).flatMap(\.hits)
        #expect(first.map(\.title) == ["chapter 1", "chapter 1", "chapter 3"])
    }

    @Test("in-book matches are what the reader highlights: the whole query, anywhere, any case and accent")
    func matchesLikeTheReader() async throws {
        let lib = TestLibrary()
        let (document, _) = try await lib.book(chapters: ["Café BOULEVARD, the white\n  whale; a whaler"])
        func matches(_ query: String) async throws -> [String] {
            try await lib.services.search.search(query, in: .document(document.id, [.text])).flatMap(\.hits)
                .flatMap { $0.snippet.segments.filter(\.isMatch).map(\.text) }
        }
        #expect(try await matches("cafe boulevard") == ["Café BOULEVARD"])
        #expect(try await matches("white whale") == ["white whale"])  // across a line break
        #expect(try await matches("hale") == ["hale", "hale"])  // inside words, as the reader finds them
        #expect(try await matches("whale white").isEmpty)  // a phrase, not loose words
    }

    @Test("a chosen match is pinned by its words, and that anchor finds it again in its chapter")
    func anchorsFindTheirMatch() async throws {
        let lib = TestLibrary()
        let text = "Call me Ishmael. The whale, the whale!\nAnd the WHALE again."
        let (document, _) = try await lib.book(chapters: [text])
        let hits = try await lib.services.search.search("the whale", in: .document(document.id, [.text])).flatMap(\.hits)
        var found: [Int] = []
        for hit in hits {
            guard case .bookText(_, let chunk, _, let match) = hit.destination else { continue }
            let anchor = try await lib.services.search.anchor(in: document.id, chunk: chunk, match: match)
            if let start = anchor?.resolve(in: text)?.lowerBound { found.append(start) }
        }
        let expected = FoldedText.ranges(of: "the whale", in: text, ignoringCase: true).map(\.lowerBound)
        #expect(expected.count == 3)
        #expect(found == expected)
    }

    @Test("in-book snippets show each match in its own context, cut at words")
    func perMatchSnippets() async throws {
        let lib = TestLibrary()
        let filler = Array(repeating: "lorem ipsum dolor", count: 10).joined(separator: " ")
        let (document, _) = try await lib.book(chapters: ["whale \(filler) final  whale"])
        let hits = try await lib.services.search.search("whale", in: .document(document.id, [.text])).flatMap(\.hits)
        #expect(hits.count == 2)
        let first = hits[0].snippet.segments
        #expect(first.first == .init(text: "whale", isMatch: true))
        #expect(first.last?.text.hasSuffix("…") == true)
        let last = hits[1].snippet.segments
        #expect(last.last == .init(text: "whale", isMatch: true))
        #expect(last.first?.text.hasPrefix("…") == true)
        #expect(last.first?.text.hasSuffix("final ") == true)  // whitespace runs collapse
        #expect(!(last.first?.text.dropFirst().hasPrefix(" ") ?? true))
    }

    @Test("the book-text matcher never overlaps matches")
    func nonOverlapping() {
        #expect(BookTextMatcher(query: "aa").ranges(in: "aaaaa") == [0..<2, 2..<4])
        #expect(BookTextMatcher(query: "  ").isEmpty)
        #expect(BookTextMatcher(query: "e").ranges(in: "É e\u{301}") == [0..<1, 2..<4])
    }

    @Test("snippets keep text outside ascii intact")
    func unicodeSnippets() {
        let text = "“Call me Ishmael,” she said — 🐋 whale 🐳 — naïve"
        let units = Array(text.utf16)
        let range = BookTextMatcher(query: "whale").ranges(in: text)[0]
        #expect(Snippet.excerpt(around: range, in: units).plainText == text)
        // A cut never splits a surrogate pair.
        let tight = Snippet.excerpt(around: range, in: units, before: 3, after: 3).plainText
        #expect(!tight.unicodeScalars.contains("\u{FFFD}"))
        #expect(tight.contains("whale"))
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
