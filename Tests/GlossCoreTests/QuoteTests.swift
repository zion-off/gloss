import Foundation
import Testing
@testable import GlossCore
import GlossMarkdown
import GlossTestSupport

/// The shared resolution cases: the reader's TypeScript twin (web/test/quote.test.ts) runs the
/// same file, so the CLI's anchors land on the same words in both.
@Suite("quote anchors")
struct QuoteAnchorTests {
    struct Case: Decodable {
        var name: String
        var source: String
        var anchor: QuoteAnchor
        var expected: [Int]?
    }

    static let cases: [Case] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/quotes/resolve.json")
        return (try? JSONDecoder().decode([Case].self, from: Data(contentsOf: url))) ?? []
    }()

    @Test("the shared resolution cases")
    func sharedCases() {
        #expect(Self.cases.count > 10)
        for item in Self.cases {
            let range = item.anchor.resolve(in: item.source)
            #expect(range.map { [$0.lowerBound, $0.upperBound] } == item.expected, "\(item.name)")
        }
    }

    @Test("an anchor records the occurrence and context, and resolves back to its own words")
    func roundTrip() {
        let text = "the whale. And then the whale.\nAnd the whale again, the whale."
        let ranges = FoldedText.ranges(of: "the whale", in: text)
        #expect(ranges.count == 4)
        for (index, range) in ranges.enumerated() {
            let anchor = QuoteAnchor(range: range, in: text)
            #expect(anchor.text == "the whale")
            #expect(anchor.occurrence == index)
            #expect(anchor.resolve(in: text) == range)
            // Reflowed by a reader (no line break, doubled spaces): still the same occurrence.
            let reflowed = text.replacingOccurrences(of: "\n", with: "  ")
            #expect(anchor.resolve(in: reflowed) == FoldedText.ranges(of: "the whale", in: reflowed)[index])
        }
        let third = QuoteAnchor(range: ranges[2], in: text)
        #expect(third.prefix == "e whale. And then the whale. And")
        #expect(third.suffix == "again, the whale.")
    }

    @Test("folding: collapsed spaces must meet spaces, stripped ignores them, case is optional")
    func folding() {
        #expect(FoldedText.ranges(of: "me  Ishmael", in: "Call me\nIshmael.") == [5..<15])
        #expect(FoldedText.ranges(of: "meIshmael", in: "Call me Ishmael").isEmpty)
        #expect(FoldedText.ranges(of: "meIshmael", in: "Call me Ishmael", whitespace: .stripped) == [5..<15])
        #expect(FoldedText.ranges(of: "ISHMAEL", in: "Ishmael").isEmpty)
        #expect(FoldedText.ranges(of: "ISHMAEL", in: "Ishmael", ignoringCase: true) == [0..<7])
        #expect(FoldedText.ranges(of: "aa", in: "aaa") == [0..<2, 1..<3])
        #expect(FoldedText.ranges(of: "the", in: "Mother, the thermos", wholeWords: true) == [8..<11])
        #expect(FoldedText.ranges(of: "Ahab!", in: "Ahab!x", wholeWords: true) == [0..<5])
    }

    @Test("scripts without spaces between words always have word edges")
    func spacelessScripts() {
        #expect(FoldedText.ranges(of: "喜欢", in: "我喜欢读书", wholeWords: true) == [1..<3])
        #expect(FoldedText.ranges(of: "クジラ", in: "ぼくはクジラが好き", wholeWords: true) == [3..<6])
        #expect(FoldedText.ranges(of: "อ่านหนังสือ", in: "ฉันชอบอ่านหนังสือ", wholeWords: true) == [6..<17])
        #expect(FoldedText.ranges(of: "gloss", in: "我喜欢gloss这本书", wholeWords: true) == [3..<8])
        #expect(FoldedText.ranges(of: "the", in: "我喜欢mother", wholeWords: true).isEmpty)
    }
}

@Suite("book text references")
struct BookTextRefTests {
    @Test("refs round-trip and reject nonsense")
    func refs() {
        let ref = BookTextRef(string: "epub-section:5@1204-1251")
        #expect(ref?.chunk == Locator(scheme: LocatorScheme("epub-section"), value: "5"))
        #expect(ref?.range == 1204..<1251)
        #expect(ref?.description == "epub-section:5@1204-1251")
        #expect(BookTextRef(string: "fake:section-0@3-9")?.chunk.value == "section-0")
        for bad in ["epub-section:5", "epub-section:5@9-3", "5@1-2", ":5@1-2", "epub-section:@1-2", "x:y@a-b", "x:y@-1-2"] {
            #expect(BookTextRef(string: bad) == nil, "\(bad)")
        }
    }
}

@Suite("finding passages in book text")
struct PassageFinderTests {
    static let chapters = [
        "Call me Ishmael. Some years ago, never mind how long, the whale.",
        "The whale! said Ahab. Not the whale, said Starbuck. A white whale.",
        "Chapter 3. Nothing about whales here.",
    ]

    func book() async throws -> (TestLibrary, BookText) {
        let library = TestLibrary()
        let (document, _) = try await library.book(chapters: Self.chapters)
        return (library, try await library.services.passages.text(of: document.id))
    }

    @Test("every match is a candidate in reading order, with labels, refs and context")
    func duplicates() async throws {
        let (_, text) = try await book()
        #expect(try text.candidates(for: BookTextQuery(.quote("hale"))).isEmpty)
        let found = try text.candidates(for: BookTextQuery(.quote("the whale")))
        #expect(found.map(\.ref.description) == ["fake:section-0@54-63", "fake:section-1@26-35"])
        #expect(found.map(\.label) == ["chapter 1", "chapter 2"])
        #expect(found.map(\.part) == [1, 2])
        #expect(found[1].before == "The whale! said Ahab. Not ")
        #expect(found[1].after == ", said Starbuck. A white whale.")
        let insensitive = try text.candidates(for: BookTextQuery(.quote("the whale"), ignoringCase: true))
        #expect(insensitive.count == 3)
        // Progression grows through the book.
        #expect(insensitive.map { $0.passage.progression ?? 0 } == insensitive.map { $0.passage.progression ?? 0 }.sorted())
    }

    @Test("part, chapter, before and after narrow the candidates")
    func selectors() async throws {
        let (_, text) = try await book()
        let all = BookTextQuery(.quote("whale"), ignoringCase: true)
        #expect(try text.candidates(for: all).count == 4)  // not "whales"
        var query = all
        query.part = 2
        #expect(try text.candidates(for: query).count == 3)
        query.after = ", said starbuck"
        #expect(try text.candidates(for: query).map(\.ref.description) == ["fake:section-1@30-35"])
        query = all
        query.before = "a  white"
        #expect(try text.candidates(for: query).map(\.ref.description) == ["fake:section-1@60-65"])
        query = all
        query.chapter = "1"
        #expect(try text.candidates(for: query).count == 1)
        query = all
        query.chunk = Locator(scheme: FakeFormat.scheme, value: "section-1")
        #expect(try text.candidates(for: query).count == 3)
        #expect(BookText.label("Chapter 3. Loomings", hasWords: "3"))
        #expect(!BookText.label("chapter 30", hasWords: "3"))
        #expect(BookText.label("Chapter 3. Loomings", hasWords: "LOOMINGS"))
    }

    @Test("a span runs from its start words through the first end words after them")
    func span() async throws {
        let (_, text) = try await book()
        let found = try text.candidates(for: BookTextQuery(.span(from: "Not the", through: "whale")))
        #expect(found.count == 1)
        #expect(found[0].passage.quote == "Not the whale")
        let long = try text.candidates(for: BookTextQuery(.span(from: "Call me", through: "the whale.")))
        #expect(long.first?.passage.quote == "Call me Ishmael. Some years ago, never mind how long, the whale.")
        #expect(try text.candidates(for: BookTextQuery(.span(from: "Chapter 3", through: "Ishmael"))).isEmpty)
        // Each end is whole words on its own: "end" is not inside "legend", "the" not in "theory".
        let legend = BookText(documentID: DocumentID(GlossID(high: 1, low: 1)), chunks: [
            TextChunk(locator: Locator(scheme: FakeFormat.scheme, value: "section-0"), label: nil, text: "the legend of theory and the end"),
        ], locating: FakeFormat())
        #expect(try legend.candidates(for: BookTextQuery(.span(from: "the", through: "end"))).map(\.passage.quote)
                == ["the legend of theory and the end", "the end"])
    }

    @Test("refs and offsets address exact text, and say when they point nowhere")
    func exact() async throws {
        let (_, text) = try await book()
        let byRef = try text.candidates(for: BookTextQuery(.ref(BookTextRef(string: "fake:section-1@26-35")!)))
        #expect(byRef.first?.passage.quote == "the whale")
        #expect(byRef.first?.says("THE  whale", ignoringCase: true) == true)
        #expect(byRef.first?.says("the wale", ignoringCase: false) == false)
        let byOffsets = try text.candidates(for: BookTextQuery(.offsets(part: 2, range: 26..<35)))
        #expect(byOffsets == byRef)
        #expect(throws: GlossError.self) { try text.candidates(for: BookTextQuery(.offsets(part: 9, range: 0..<3))) }
        #expect(throws: GlossError.self) { try text.candidates(for: BookTextQuery(.offsets(part: 1, range: 0..<999))) }
        #expect(throws: GlossError.self) { try text.candidates(for: BookTextQuery(.ref(BookTextRef(string: "fake:nope@0-3")!))) }
        #expect(throws: GlossError.self) { try text.candidates(for: BookTextQuery(.offsets(part: 1, range: 4..<5))) }
    }

    @Test("the same occurrence makes the same locator, so its link target is reused")
    func stableLocators() async throws {
        let (library, text) = try await book()
        let first = try text.candidates(for: BookTextQuery(.quote("the whale")))
        let again = try text.candidates(for: BookTextQuery(.quote("THE WHALE"), ignoringCase: true))
        #expect(first[0].passage.locator == again[0].passage.locator)
        #expect(first[0].passage.locator != first[1].passage.locator)
        let a = try await library.services.links.target(for: first[0].passage, in: text.documentID)
        let b = try await library.services.links.target(for: again[0].passage, in: text.documentID)
        #expect(a.id == b.id)
    }
}

@Suite("a book's parts and where passages sit")
struct BookTextPartsTests {
    static let chapters = [
        "Replication\nKeeping a copy of the same data on several machines.\nLeaders and Followers\nEach node that stores a copy is a replica.",
        "Partitioning\nA copy of the same data, but split. Each node that stores a copy is a replica.",
    ]

    func book() async throws -> BookText {
        let library = TestLibrary()
        let (document, _) = try await library.book(chapters: Self.chapters)
        return try await library.services.passages.text(of: document.id)
    }

    func passage(_ quote: String, section: Int? = nil) -> Passage {
        Passage(locator: Locator(scheme: section == nil ? LocatorScheme("elsewhere") : FakeFormat.scheme,
                                 value: section.map { "section-\($0)" } ?? "x"), quote: quote)
    }

    @Test("parts list in reading order with numbers, labels and lengths, and select by number or label words")
    func parts() async throws {
        let text = try await book()
        #expect(text.parts.map(\.number) == [1, 2])
        #expect(text.parts.map(\.label) == ["chapter 1", "chapter 2"])
        #expect(text.parts[1].length == Self.chapters[1].utf16.count)
        #expect(text.parts(number: 2).map(\.index) == [1])
        #expect(text.parts(chapter: "chapter").count == 2)
        #expect(text.parts(chapter: "1").map(\.index) == [0])
        #expect(text.parts(number: 1, chapter: "2").isEmpty)
    }

    @Test("a passage's part comes from its locator, or the one part with its words; refs only for words found once")
    func places() async throws {
        let text = try await book()
        let heading = try #require(text.place(of: passage("Leaders and Followers", section: 0)))
        #expect(heading.part.number == 1)
        #expect(heading.looksLikeHeading)
        #expect(heading.ref?.description == "fake:section-0@65-86")
        // Found by its words alone when the locator doesn't say.
        let elsewhere = try #require(text.place(of: passage("but  split.")))
        #expect(elsewhere.part.number == 2)
        #expect(!elsewhere.looksLikeHeading)
        #expect(elsewhere.ref?.description == "fake:section-1@38-48")
        // In both parts and the locator doesn't say: no guess.
        #expect(text.place(of: passage("a replica.")) == nil)
        // In the part the locator names, but twice: the part, no ref.
        let twice = try #require(text.place(of: passage("copy", section: 1)))
        #expect(twice.part.number == 2)
        #expect(twice.ref == nil)
        // A whole line that ends like a sentence isn't a heading.
        #expect(text.place(of: passage("Keeping a copy of the same data on several machines.", section: 0))?.looksLikeHeading == false)
        #expect(text.place(of: passage("Replication", section: 0))?.looksLikeHeading == true)
    }
}

@Suite("finding words in notes")
struct NotesTextFinderTests {
    @Test("matches skip code, link destinations and line breaks, and see the links they're in")
    func eligibility() {
        let body = """
        the whale is here, and `the whale` in code
        [the whale](gloss://passage/01jabcdefghjkmnpqrstvwxyz0) and [x](https://the.whale)
        ```
        the whale
        ```
        the
        whale
        """
        let found = NotesTextFinder.matches(of: "the whale", in: body)
        #expect(found.map(\.line) == [1, 2])
        #expect(found[0].range == 0..<9)
        #expect(found[0].after == " is here, and `the whale` in code")
        #expect(found[1].linkDestination == "gloss://passage/01jabcdefghjkmnpqrstvwxyz0")
        #expect(NotesTextFinder.matches(of: "THE WHALE", in: "The whale", ignoringCase: true).count == 1)
        #expect(NotesTextFinder.matches(of: "whale is", in: "the whale  is") .map(\.range) == [4..<13])
        #expect(NotesTextFinder.match(at: 0..<3, in: "the whale")?.text == "the")
        #expect(NotesTextFinder.match(at: 2..<12, in: "a\nb c d e f") == nil)
        #expect(NotesTextFinder.match(at: 0..<99, in: "short") == nil)
        // An offset inside an emoji's surrogate pair is refused, never spliced.
        #expect(NotesTextFinder.match(at: 1..<6, in: "😀 the whale") == nil)
        #expect(NotesTextFinder.match(at: 3..<6, in: "😀 the whale")?.text == "the")
    }

    @Test("words match as the page reads: across formatting it covers whole, through escapes, and again once linked")
    func asItReads() async throws {
        // Formatting covered whole is wrapped with the words; words inside it stay inside.
        let bold = "- a **replica** stores a copy"
        #expect(NotesTextFinder.matches(of: "a replica stores", in: bold).map(\.text) == ["a **replica** stores"])
        #expect(NotesTextFinder.matches(of: "replica", in: bold).map(\.range) == [6..<13])
        #expect(NotesTextFinder.matches(of: "a **replica** stores", in: bold).count == 1)  // as written still works
        // Cutting through formatting, or reaching into code, is no match.
        #expect(NotesTextFinder.matches(of: "replica stores", in: "a **big replica** stores").isEmpty)
        #expect(NotesTextFinder.matches(of: "big whale", in: "`the big` whale").isEmpty)
        #expect(NotesTextFinder.matches(of: "the whale", in: "`the` whale").map(\.text) == ["`the` whale"])  // code inside a link is fine
        // Escaped brackets read as brackets; the range takes the backslash with it.
        let escaped = "see \\[sic\\] here"
        #expect(NotesTextFinder.matches(of: "[sic]", in: escaped).map(\.range) == [4..<11])
        #expect(NotesTextFinder.range(4..<11, in: escaped, says: "[sic]"))
        #expect(!NotesTextFinder.range(4..<11, in: escaped, says: "[sick]"))

        // Linking words with brackets escapes them; the same words find that link again.
        let library = TestLibrary()
        let (document, _) = try await library.book(chapters: ["Call me Ishmael."])
        let page = try await library.services.pages.rootPage(of: document.id)!
        _ = try await library.services.pages.updateBody(page.id, to: "a note [with brackets] and a **bold** claim")
        let passage = try await library.services.passages.text(of: document.id).candidates(for: BookTextQuery(.quote("Ishmael")))[0].passage
        for words in ["note [with brackets]", "a bold claim"] {
            let first = try #require(NotesTextFinder.matches(of: words, in: try await library.services.pages.page(page.id)!.body).first)
            let linked = try await library.services.links.link(first.range, expecting: first.text, in: page.id, to: passage, in: document.id)
            #expect(linked.change == .linked)
            let again = try #require(NotesTextFinder.matches(of: words, in: linked.page.body).first)
            #expect(again.linkDestination != nil)
            let relinked = try await library.services.links.link(again.range, expecting: again.text, in: page.id, to: passage, in: document.id)
            #expect(relinked.change == .alreadyLinked)
        }
        let body = try await library.services.pages.page(page.id)!.body
        #expect(body.hasPrefix("a [note \\[with brackets\\]](gloss://passage/"))
        #expect(body.contains(" and [a **bold** claim](gloss://passage/"))
    }
}

@Suite("linking words in notes")
struct NotesLinkTests {
    @Test("wraps the words, reuses the target, and linking again changes nothing")
    func idempotent() async throws {
        let library = TestLibrary()
        let (document, page) = try await library.book(chapters: ["the whale and the sea"])
        _ = try await library.services.pages.updateBody(page.id, to: "I love the sea. The sea!")
        let text = try await library.services.passages.text(of: document.id)
        let passage = try text.candidates(for: BookTextQuery(.quote("the sea")))[0].passage
        let range = NotesTextFinder.matches(of: "the sea", in: "I love the sea. The sea!")[0].range
        let first = try await library.services.links.link(range, expecting: "the sea", in: page.id, to: passage, in: document.id)
        #expect(first.change == .linked)
        let url = GlossLink.passage(first.target.id).string
        #expect(first.page.body == "I love [the sea](\(url)). The sea!")
        #expect(MarkdownText(first.page.body)[first.range] == "[the sea](\(url))")
        // The target is live (referenced), so the reader draws its marker.
        #expect(try await library.services.links.linkedPassages(in: document.id).map(\.target.id) == [first.target.id])

        let again = NotesTextFinder.matches(of: "the sea", in: first.page.body)[0]
        let second = try await library.services.links.link(again.range, expecting: "the sea", in: page.id, to: passage, in: document.id)
        #expect(second.change == .alreadyLinked)
        #expect(second.target.id == first.target.id)
        #expect(second.page.body == first.page.body)
    }

    @Test("words inside another link re-point it; a changed page writes nothing")
    func relinkAndStale() async throws {
        let library = TestLibrary()
        let (document, page) = try await library.book(chapters: ["the whale and the sea"])
        _ = try await library.services.pages.updateBody(page.id, to: "see [the sea](https://sea.example)")
        let text = try await library.services.passages.text(of: document.id)
        let passage = try text.candidates(for: BookTextQuery(.quote("the sea")))[0].passage
        let result = try await library.services.links.link(5..<12, expecting: "the sea", in: page.id, to: passage, in: document.id)
        #expect(result.change == .relinked(from: "https://sea.example"))
        #expect(result.page.body == "see [the sea](\(GlossLink.passage(result.target.id).string))")
        await #expect(throws: GlossError.self) {
            try await library.services.links.link(0..<3, expecting: "the", in: page.id, to: passage, in: document.id)
        }
    }
}
