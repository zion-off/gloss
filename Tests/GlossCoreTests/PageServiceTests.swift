import Foundation
import Testing
@testable import GlossCore
import GlossTestSupport

@Suite("pages")
struct PageServiceTests {
    @Test("subpages build a tree with breadcrumbs")
    func tree() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book()
        let a = try await lib.services.pages.createSubpage(under: root.id, title: "a")
        let b = try await lib.services.pages.createSubpage(under: root.id, title: "b")
        let a1 = try await lib.services.pages.createSubpage(under: a.id, title: "a1")
        let tree = try await lib.services.pages.tree(of: document.id)
        #expect(tree.root.walk().map { "\($0.depth):\($0.page.title)" } == ["0:A Book", "1:a", "2:a1", "1:b"])
        #expect(try await lib.services.pages.breadcrumbs(to: a1.id).map(\.title) == ["A Book", "a", "a1"])
        #expect(b.position > a.position)
    }

    @Test("the block line marks placement; removing it never orphans the page")
    func placement() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "chapter notes", appendBlockLine: true)
        let body = try #require(try await lib.services.pages.page(root.id)).body
        #expect(body == "[chapter notes](gloss://page/\(child.id))\n")
        #expect(try await lib.services.pages.unplacedChildren(of: root.id).isEmpty)
        try await lib.services.pages.updateBody(root.id, to: "")
        #expect(try await lib.services.pages.unplacedChildren(of: root.id).map(\.id) == [child.id])
        #expect(try await lib.services.pages.children(of: root.id).map(\.id) == [child.id])
    }

    @Test("renaming updates block-line labels that still show the old title")
    func renameSync() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "draft", appendBlockLine: true)
        try await lib.services.pages.append("[my own words](gloss://page/\(child.id)) inline stays", to: root.id)
        try await lib.services.pages.rename(child.id, to: "final [v2]")
        let body = try #require(try await lib.services.pages.page(root.id)).body
        #expect(body.hasPrefix("[final \\[v2\\]](gloss://page/\(child.id))\n"))
        #expect(body.contains("[my own words](gloss://page/\(child.id)) inline stays"))
    }

    @Test("block lines are only lines that are nothing but a page link")
    func blockLines() {
        let id = PageID(GlossID(high: 0x7000, low: 1))
        let body = """
        [a](gloss://page/\(id))
          [b](gloss://page/\(id))  
        - [c](gloss://page/\(id))
        see [d](gloss://page/\(id))
        [e](gloss://passage/\(id))
        """
        #expect(PageBlockLines.find(in: body).map(\.label) == ["a", "b"])
    }

    @Test("trashed pages cannot be edited")
    func trashedEdits() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id)
        try await lib.services.trash.trash(.page, id: child.id.stringValue)
        await #expect(throws: GlossError.inTrash("this page")) { try await lib.services.pages.updateBody(child.id, to: "x") }
    }

    @Test("bodies are stored exactly as written")
    func rawBodies() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let weird = "#  spaced   heading\n\n\n*   loose list\r\n__x__ `y`  \n"
        try await lib.services.pages.updateBody(root.id, to: weird)
        #expect(try await lib.services.pages.page(root.id)?.body == weird)
    }
}

@Suite("quote lines")
struct QuoteLineTests {
    let id = LinkTargetID(GlossID(high: 0x7000, low: 9))

    @Test("quote lines escape the quote and link back with an arrow")
    func make() {
        #expect(QuoteLine.make(quote: "the *absurd*\n hero", target: id) == "> the \\*absurd\\* hero [↗](gloss://passage/\(id))")
    }

    @Test("inserting at the end starts a new line")
    func atEnd() {
        #expect(QuoteInsertion.insert("> q", into: "", at: nil).body == "> q\n")
        #expect(QuoteInsertion.insert("> q", into: "text", at: nil).body == "text\n> q\n")
        let result = QuoteInsertion.insert("> q", into: "text\n", at: nil)
        #expect(result.body == "text\n> q\n")
        #expect(result.insertedRange == 5..<8)
    }

    @Test("inserting at the caret puts the quote on its own line")
    func atCaret() {
        #expect(QuoteInsertion.insert("> q", into: "ab", at: 1).body == "a\n> q\nb")
        #expect(QuoteInsertion.insert("> q", into: "a\nb", at: 2).body == "a\n> q\nb")
        #expect(QuoteInsertion.insert("> q", into: "a\nb", at: 1).body == "a\n> q\nb")
        #expect(QuoteInsertion.insert("> q", into: "ab", at: 2).body == "ab\n> q\n")
    }
}
