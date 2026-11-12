import Foundation
import Testing
@testable import GlossExport
import GlossCore
import GlossTestSupport

@Suite("export")
struct ExportTests {
    func exportText(_ lib: TestLibrary, _ scope: ExportScope, _ format: ExportFormat = .markdown) async throws -> String {
        let service = ExportService(store: lib.store)
        return String(decoding: try await service.export(scope, as: format).data, as: UTF8.self)
    }

    @Test("a book exports as one markdown file with subpages as nested headings")
    func nestedHeadings() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book("The Plague", author: "Albert Camus")
        try await lib.services.pages.updateBody(root.id, to: "first thoughts\n## a heading in the root")
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "Rieux", appendBlockLine: true)
        try await lib.services.pages.updateBody(child.id, to: "# his duty\nkeeps working")
        let grandchild = try await lib.services.pages.createSubpage(under: child.id, title: "Tarrou")
        try await lib.services.pages.updateBody(grandchild.id, to: "saints without god")
        let text = try await exportText(lib, .document(document.id))
        #expect(text == """
        # The Plague

        *The Plague* · Albert Camus

        first thoughts
        ### a heading in the root
        [Rieux](#rieux)

        ## Rieux

        ### his duty
        keeps working

        ### Tarrou

        saints without god

        """)
    }

    @Test("quote lines keep the quote and gain a location; other passage links become footnotes")
    func passages() async throws {
        let lib = TestLibrary()
        let (camus, camusRoot) = try await lib.book("The Myth")
        let (didion, _) = try await lib.book("The White Album")
        let sisyphus = try await lib.services.links.target(for: Passage(locator: Locator(scheme: FakeFormat.scheme, value: "1"),
                                                                        quote: "one must imagine *Sisyphus* happy", label: "chapter 4"), in: camus.id)
        let story = try await lib.services.links.target(for: Passage(locator: Locator(scheme: FakeFormat.scheme, value: "2"),
                                                                     quote: "we tell ourselves stories", label: "page 11"), in: didion.id)
        let body = """
        \(QuoteLine.make(quote: "one must imagine *Sisyphus* happy", target: sisyphus.id))
        compare [this line](gloss://passage/\(story.id)) and [again](gloss://passage/\(story.id)).
        dead [link](gloss://passage/0000000000000000000000000z) stays as text.
        """
        try await lib.services.pages.updateBody(camusRoot.id, to: body)
        let text = try await exportText(lib, .document(camus.id))
        #expect(text.contains("> one must imagine \\*Sisyphus\\* happy — *chapter 4*\n\ncompare"))
        #expect(text.contains("compare this line[^1] and again[^1]."))
        #expect(text.contains("dead link stays as text."))
        #expect(text.hasSuffix("[^1]: “we tell ourselves stories” — page 11, *The White Album*\n"))
    }

    @Test("a single page or a subtree can be exported; outside page links degrade")
    func pageScopes() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let a = try await lib.services.pages.createSubpage(under: root.id, title: "a")
        let b = try await lib.services.pages.createSubpage(under: a.id, title: "b")
        try await lib.services.pages.updateBody(a.id, to: "see [the root](gloss://page/\(root.id)) and [b](gloss://page/\(b.id))")
        let single = try await exportText(lib, .page(a.id, includeSubpages: false))
        #expect(single == "# a\n\nsee the root and b\n")
        let subtree = try await exportText(lib, .page(a.id, includeSubpages: true))
        #expect(subtree == "# a\n\nsee the root and [b](#b)\n\n## b\n")
    }

    @Test("duplicate titles get unique anchors")
    func anchors() {
        var slugger = Slugger()
        #expect(slugger.slug("Notes!") == "notes")
        #expect(slugger.slug("notes") == "notes-1")
        #expect(slugger.slug("??") == "page")
    }

    @Test("html export renders structure, footnotes and escapes text")
    func html() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book("A <Book>")
        try await lib.services.pages.updateBody(root.id, to: """
        para one
        line two

        - [x] done
          - nested
        1. first
        > quoted **bold**
        > more
        ```
        <code>
        ```
        """)
        let html = try await exportText(lib, .document(document.id), .html)
        #expect(html.contains("<title>A &lt;Book&gt;</title>"))
        #expect(html.contains("<p>para one<br>\nline two</p>"))
        #expect(html.contains("<ul class=\"tasks\">\n<li><input type=\"checkbox\" disabled checked> done\n<ul>\n<li>nested\n</li></ul>\n</li></ul>"))
        #expect(html.contains("<ol>\n<li>first\n</li></ol>"))
        #expect(html.contains("<blockquote><p>quoted <strong>bold</strong><br>\nmore</p></blockquote>"))
        #expect(html.contains("<pre><code>&lt;code&gt;</code></pre>"))
    }

    @Test("footnotes render as a linked list")
    func footnotesHTML() {
        let html = HTMLRenderer().render("text[^1]\n\n[^1]: “a quote” — page 2")
        #expect(html.contains("<sup><a href=\"#fn-1\">1</a></sup>"))
        #expect(html.contains("<li id=\"fn-1\">“a quote” — page 2</li>"))
    }

    @Test("file names are safe and default sensibly")
    func filenames() {
        #expect(ExportService.filename(for: "Slouching: Towards/Bethlehem?", extension: "md") == "Slouching- Towards-Bethlehem.md")
        #expect(ExportService.filename(for: "///", extension: "html") == "gloss notes.html")
    }

    @Test("unknown formats are refused")
    func unknownFormat() async throws {
        let lib = TestLibrary()
        let (document, _) = try await lib.book()
        await #expect(throws: GlossError.self) {
            try await ExportService(store: lib.store).export(.document(document.id), as: ExportFormat("docx"))
        }
    }
}
