import Foundation
import Testing
@testable import GlossNotes
import GlossCore
import GlossMarkdown
import GlossTestSupport

@Suite("notes styling")
struct NotesStylingTests {
    let target = LinkTargetID(GlossID(high: 0x7000, low: 1))
    let page = PageID(GlossID(high: 0x7000, low: 2))

    @Test("gloss links are classified by kind and status")
    func classification() {
        let source = "[a](gloss://passage/\(target)) [b](gloss://page/\(page)) [c](https://x.y)"
        let doc = MarkdownParser.standard.parse(source)
        let roles = { (styler: NotesStyler) in styler.spans(for: doc).map { doc.text[$0.range] + ":" + $0.role.rawValue } }
        #expect(roles(NotesStyler()).contains("a:passageLink"))
        #expect(roles(NotesStyler()).contains("b:pageLink"))
        #expect(!roles(NotesStyler()).contains { $0.hasPrefix("c:") && $0.contains("Link") && !$0.hasSuffix(":link") })
        let broken = roles(NotesStyler(statuses: [.passage(target): .missing, .page(page): .inTrash]))
        #expect(broken.contains("a:brokenLink"))
        #expect(broken.contains("b:trashedLink"))
        #expect(NotesStyler.glossLinks(in: doc) == [.passage(target), .page(page)])
    }

    @Test("subpage rows only cover block lines of child pages, with live titles")
    func rows() {
        let now = Date.testEpoch
        let doc = DocumentID(GlossID(high: 0x7000, low: 3))
        let child = Page(id: page, documentID: doc, parentID: PageID(GlossID(high: 0x7000, low: 4)), title: "renamed", body: "",
                         position: 1, createdAt: now, updatedAt: now)
        let other = PageID(GlossID(high: 0x7000, low: 5))
        let source = "[old label](gloss://page/\(page))\n[x](gloss://page/\(other))"
        let parsed = MarkdownParser.standard.parse(source)
        let rows = SubpageRows.rows(in: parsed, children: [child])
        #expect(rows.map(\.title) == ["renamed"])
        #expect(rows.first?.lineRange == parsed.text.lines[0])
        #expect(NotesStyler().spans(for: parsed, subpageRows: rows).contains { $0.role == NotesRole.subpageBlock })
        #expect(!FormatBar.shouldShow(selection: 1..<4, subpageRows: rows))
        #expect(FormatBar.shouldShow(selection: 55..<57, subpageRows: rows))
        #expect(!FormatBar.shouldShow(selection: 2..<2, subpageRows: rows))
    }
}

@Suite("slash commands")
struct SlashCommandTests {
    func trigger(_ marked: String) -> SlashTrigger? {
        let caret = marked.utf16.firstIndex(of: 0x7C).map { marked.utf16.distance(from: marked.utf16.startIndex, to: $0) }!
        let text = marked.replacingOccurrences(of: "|", with: "")
        return SlashTrigger.detect(in: MarkdownParser.standard.parse(text), caret: caret)
    }

    @Test("triggers start at a line start or after a space and stay out of code")
    func detection() {
        #expect(trigger("/pa|")?.query == "pa")
        #expect(trigger("text /|")?.query == "")
        #expect(trigger("text /h1|")?.range == 5..<8)
        #expect(trigger("a/b|") == nil)
        #expect(trigger("`/pa|`") == nil)
        #expect(trigger("```\n/pa|\n```") == nil)
        #expect(trigger("/" + String(repeating: "a", count: 30) + "|") == nil)
        #expect(trigger("no trigger|") == nil)
    }

    @Test("matching ranks exact, prefix, word, keyword, then fuzzy")
    func ranking() {
        let registry = SlashCommandRegistry.standard(pages: TestLibrary().services.pages)
        #expect(registry.matches("").count == 10)
        #expect(registry.matches("page").first?.id == "page")
        #expect(registry.matches("h2").first?.id == "h2")
        #expect(registry.matches("list").map(\.id).prefix(2) == ["bullet", "numbered"])
        #expect(registry.matches("task").first?.id == "todo")
        #expect(registry.matches("bl").first?.id == "bullet")
        #expect(registry.matches("zzz").isEmpty)
    }

    @Test("formatting commands replace the trigger in one edit")
    func formatting() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let registry = SlashCommandRegistry.standard(pages: lib.services.pages)
        let source = "intro\n/to"
        let doc = MarkdownParser.standard.parse(source)
        let trig = try #require(SlashTrigger.detect(in: doc, caret: source.utf16.count))
        let command = try #require(registry.matches(trig.query).first)
        let result = try await registry.run(command, trigger: trig, in: doc, page: root.id)
        let applied = EditResult(edits: [result.edit], selection: result.selection).apply(to: source)
        #expect(applied == "intro\n- [ ] ")
        #expect(result.selection == 12..<12)
    }

    @Test("/page creates a subpage, places its block line and opens it")
    func newPage() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let registry = SlashCommandRegistry.standard(pages: lib.services.pages)
        for source in ["/page", "some text /pa"] {
            let doc = MarkdownParser.standard.parse(source)
            let trig = try #require(SlashTrigger.detect(in: doc, caret: source.utf16.count))
            let result = try await registry.run(registry.matches("page")[0], trigger: trig, in: doc, page: root.id)
            let child = try #require(result.openPage)
            let applied = EditResult(edits: [result.edit], selection: result.selection).apply(to: source)
            let line = "[untitled](gloss://page/\(child))"
            #expect(applied == (source == "/page" ? line : "some text \n" + line))
            #expect(try await lib.services.pages.page(child)?.parentID == root.id)
        }
    }

    @Test("minimal diffs keep shared prefixes and suffixes")
    func diff() {
        #expect(TextDiff.minimalEdit(from: "hello world", to: "hello brave world") == TextEdit(range: 6..<6, replacement: "brave "))
        #expect(TextDiff.minimalEdit(from: "same", to: "same") == nil)
        #expect(TextDiff.minimalEdit(from: "a🌙b", to: "a🌞b") == TextEdit(range: 1..<3, replacement: "🌞"))
    }
}

@Suite("format bar")
struct FormatBarTests {
    @Test("items are in the specified order with standard shortcuts")
    func items() {
        #expect(FormatBar.items.map(\.id) == ["bold", "italic", "heading", "list", "quote", "code", "link"])
        #expect(FormatBar.items[0].shortcutLabel == "⌘B")
        #expect(FormatBar.items.last?.shortcutLabel == "⇧⌘K")
    }

    @Test("active items reflect the selection")
    func active() {
        let doc = MarkdownParser.standard.parse("## **bold** words")
        #expect(FormatBar.activeItems(in: doc, selection: 5..<7) == ["bold", "heading"])
    }

    @Test("the heading button cycles 1, 2, 3, off")
    func cycle() {
        var text = "title"
        for expected in ["# title", "## title", "### title", "title"] {
            let doc = MarkdownParser.standard.parse(text)
            text = CycleHeading().edit(doc, selection: 0..<0)!.apply(to: text)
            #expect(text == expected)
        }
    }
}

@Suite("link gesture")
struct LinkGestureTests {
    let page = PageID(GlossID(high: 0x7000, low: 1))
    let doc = DocumentID(GlossID(high: 0x7000, low: 2))
    var passage: Passage { Passage(locator: Locator(scheme: LocatorScheme("x"), value: "1"), quote: "the passage") }

    @Test("either order works; one side alone explains what's missing")
    func availability() {
        let text = MarkdownParser.standard.parse("some words here")
        let notes = NotesSelection(pageID: page, range: 5..<10)
        let book = BookSelection(documentID: doc, passage: passage)
        #expect(LinkGesture.availability(notes: notes, book: book, document: text) == .ready)
        #expect(LinkGesture.availability(notes: notes, book: nil, document: text) == .needsBookSelection)
        #expect(LinkGesture.availability(notes: nil, book: book, document: text) == .needsNotesSelection)
        #expect(LinkGesture.availability(notes: NotesSelection(pageID: page, range: 3..<3), book: nil, document: text) == .needsBoth)
        #expect(LinkGesture.availability(notes: NotesSelection(pageID: page, range: 0..<0), book: book, document: text).hint == "now select some words in your notes")
    }

    @Test("selections that can't be links are reported")
    func notLinkable() {
        let text = MarkdownParser.standard.parse("line one\nline two")
        let notes = NotesSelection(pageID: page, range: 2..<12)
        #expect(LinkGesture.availability(notes: notes, book: BookSelection(documentID: doc, passage: passage), document: text) == .notLinkable)
    }

    @Test("performing wraps the words in a passage link")
    func perform() {
        let target = LinkTargetID(GlossID(high: 0x7000, low: 9))
        let source = "some words here"
        let result = LinkGesture.edit(in: MarkdownParser.standard.parse(source), selection: 5..<10, target: target)!
        #expect(result.apply(to: source) == "some [words](gloss://passage/\(target)) here")
    }

    @Test("add to notes inserts a quote line at the caret or the end")
    func quote() {
        let target = LinkTargetID(GlossID(high: 0x7000, low: 9))
        let atCaret = LinkGesture.quoteInsertion(of: passage, target: target, into: "a\nb", caret: 1)
        #expect(atCaret.body == "a\n> the passage [↗](gloss://passage/\(target))\nb")
        let atEnd = LinkGesture.quoteInsertion(of: passage, target: target, into: "a", caret: nil)
        #expect(atEnd.body.hasSuffix("[↗](gloss://passage/\(target))\n"))
    }
}
