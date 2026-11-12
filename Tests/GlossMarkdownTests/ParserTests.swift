import Testing
@testable import GlossMarkdown

/// Renders inlines as `kind(content…)` with plain text between, for compact assertions.
func outline(_ source: String) -> String {
    let doc = MarkdownParser.standard.parse(source)
    return doc.blocks.map { block in render(block, doc.text) }.joined(separator: " | ")
}

private func render(_ block: Block, _ text: MarkdownText) -> String {
    var head = block.kind.rawValue
    if let level = block.attributes.level { head += "\(level)" }
    if block.kind == .listItem {
        head += block.attributes.ordered == true ? "#\(block.attributes.number ?? 0)" : "-"
        if let indent = block.attributes.indent, indent > 0 { head += ">\(indent)" }
        if let checked = block.attributes.checked { head += checked ? "[x]" : "[ ]" }
    }
    if let lang = block.attributes.language { head += ":\(lang)" }
    if !block.children.isEmpty { return head + "{" + block.children.map { render($0, text) }.joined() + "}" }
    let content = renderInlines(block.inlines, in: block.contentRange, text)
    return content.isEmpty ? head : head + " " + content
}

func renderInlines(_ inlines: [Inline], in range: Range<Int>, _ text: MarkdownText) -> String {
    var out = ""
    var cursor = range.lowerBound
    for inline in inlines {
        out += text[cursor..<inline.range.lowerBound]
        var inner = renderInlines(inline.children, in: inline.contentRange, text)
        if let destination = inline.destination { inner += "->" + destination }
        out += "\(inline.kind.rawValue)(\(inner))"
        cursor = inline.range.upperBound
    }
    out += text[cursor..<max(cursor, range.upperBound)]
    return out
}

func inlineOutline(_ source: String) -> String {
    let text = MarkdownText(source)
    return renderInlines(MarkdownParser.standard.parseInlines(in: text, range: 0..<text.length), in: 0..<text.length, text)
}

@Suite("block parsing")
struct BlockParsingTests {
    @Test("headings need a space and at most six hashes")
    func headings() {
        #expect(outline("# One") == "heading1 One")
        #expect(outline("###### Six") == "heading6 Six")
        #expect(outline("####### seven") == "paragraph ####### seven")
        #expect(outline("#tag") == "paragraph #tag")
        #expect(outline("##") == "heading2")
    }

    @Test("heading syntax covers the hashes and the following space")
    func headingSyntax() {
        let doc = MarkdownParser.standard.parse("## Title")
        #expect(doc.blocks[0].syntax == [0..<3])
        #expect(doc.blocks[0].contentRange == 3..<8)
    }

    @Test("bullet, ordered and task items with nesting")
    func lists() {
        #expect(outline("- a") == "listItem- a")
        #expect(outline("* a") == "listItem- a")
        #expect(outline("12. a") == "listItem#12 a")
        #expect(outline("3) a") == "listItem#3 a")
        #expect(outline("    - deep") == "listItem->2 deep")
        #expect(outline("- [ ] todo") == "listItem-[ ] todo")
        #expect(outline("- [x] done") == "listItem-[x] done")
        #expect(outline("- [X]") == "listItem-[x]")
        #expect(outline("-not a list") == "paragraph -not a list")
        #expect(outline("1.5 is a number") == "paragraph 1.5 is a number")
        #expect(outline("- [y] odd") == "listItem- [y] odd")
    }

    @Test("quotes contain a nested block")
    func quotes() {
        #expect(outline("> said") == "quote{paragraph said}")
        #expect(outline("> ## big") == "quote{heading2 big}")
        #expect(outline("> > twice") == "quote{quote{paragraph twice}}")
        #expect(outline("> - [ ] item") == "quote{listItem-[ ] item}")
        let doc = MarkdownParser.standard.parse("> hi")
        #expect(doc.blocks[0].syntax == [0..<2])
        #expect(doc.blocks[0].leaf.kind == .paragraph)
    }

    @Test("fenced code spans lines and keeps its language")
    func fences() {
        let doc = MarkdownParser.standard.parse("```swift\nlet *x* = 1\n```\nafter")
        #expect(doc.blocks.map(\.kind) == [.codeBlock, .paragraph])
        #expect(doc.blocks[0].attributes.language == "swift")
        #expect(doc.text[doc.blocks[0].contentRange] == "let *x* = 1")
        #expect(doc.blocks[0].inlines.isEmpty)
        #expect(doc.blocks[0].syntax.count == 2)
    }

    @Test("an unclosed fence runs to the end")
    func unclosedFence() {
        let doc = MarkdownParser.standard.parse("~~~\ncode\nmore")
        #expect(doc.blocks.count == 1)
        #expect(doc.text[doc.blocks[0].contentRange] == "code\nmore")
    }

    @Test("thematic breaks, blanks and paragraphs")
    func misc() {
        #expect(outline("---") == "thematicBreak")
        #expect(outline("* * *") == "thematicBreak")
        #expect(outline("--") == "paragraph --")
        #expect(outline("a\n\nb") == "paragraph a | blank | paragraph b")
        #expect(outline("") == "blank")
    }

    @Test("CRLF line endings are not part of lines")
    func crlf() {
        let text = MarkdownText("a\r\nb")
        #expect(text.lines == [0..<1, 3..<4])
        #expect(text.lineIndex(containing: 3) == 1)
    }
}

@Suite("inline parsing")
struct InlineParsingTests {
    @Test("emphasis, strong and strikethrough")
    func emphasis() {
        #expect(inlineOutline("*a* **b** ~~c~~") == "emphasis(a) strong(b) strikethrough(c)")
        #expect(inlineOutline("_a_ __b__") == "emphasis(a) strong(b)")
        #expect(inlineOutline("***both***") == "emphasis(strong(both))")
        #expect(inlineOutline("**bold *and* more**") == "strong(bold emphasis(and) more)")
    }

    @Test("flanking rules")
    func flanking() {
        #expect(inlineOutline("a * b * c") == "a * b * c")
        #expect(inlineOutline("snake_case_name") == "snake_case_name")
        #expect(inlineOutline("in*tra*word") == "inemphasis(tra)word")
        #expect(inlineOutline("**unclosed") == "**unclosed")
        #expect(inlineOutline("~single~") == "~single~")
    }

    @Test("code spans are opaque and need matching runs")
    func codeSpans() {
        #expect(inlineOutline("`*not em*`") == "code(*not em*)")
        #expect(inlineOutline("``a ` b``") == "code(a ` b)")
        #expect(inlineOutline("`open") == "`open")
    }

    @Test("links with nested emphasis, parens and titles")
    func links() {
        #expect(inlineOutline("[a *b*](gloss://page/x)") == "link(a emphasis(b)->gloss://page/x)")
        #expect(inlineOutline("[w](https://en.wikipedia.org/wiki/A_(b))") == "link(w->https://en.wikipedia.org/wiki/A_(b))")
        #expect(inlineOutline("[t](<a b> \"title\")") == "link(t->a b)")
        #expect(inlineOutline("[x] (y)") == "[x] (y)")
        #expect(inlineOutline("[[nested]](z)") == "link([nested]->z)")
        #expect(inlineOutline("**[bold link](u)**") == "strong(link(bold link->u))")
        #expect(inlineOutline("[`code]`](u)") == "link(code(code])->u)")
    }

    @Test("link syntax ranges cover brackets and the destination part")
    func linkRanges() {
        let text = MarkdownText("see [label](gloss://passage/abc) now")
        let link = MarkdownParser.standard.parseInlines(in: text, range: 0..<text.length)[0]
        #expect(text[link.contentRange] == "label")
        #expect(link.syntax.map { text[$0] } == ["[", "](gloss://passage/abc)"])
        #expect(text[link.destinationRange!] == "gloss://passage/abc")
    }

    @Test("escapes and autolinks")
    func escapes() {
        #expect(inlineOutline(#"\*not\*"#) == #"escape(*)notescape(*)"#)
        #expect(inlineOutline("<https://x.y/z>") == "autolink(https://x.y/z->https://x.y/z)")
        #expect(inlineOutline("a < b > c") == "a < b > c")
    }

    @Test("surrogate pairs keep UTF-16 offsets exact")
    func utf16() {
        let text = MarkdownText("🌙 **moon**")
        let strong = MarkdownParser.standard.parseInlines(in: text, range: 0..<text.length)[0]
        #expect(strong.range == 3..<11)
        #expect(text[strong.contentRange] == "moon")
    }
}
