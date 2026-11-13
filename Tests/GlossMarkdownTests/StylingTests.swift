import Testing
@testable import GlossMarkdown

@Suite("styling rules")
struct StylingTests {
    func styled(_ source: String) -> [(String, String)] {
        let doc = MarkdownParser.standard.parse(source)
        return StyleRuleSet.standard.spans(for: doc).map { (doc.text[$0.range], $0.role.rawValue) }
    }

    @Test("headings style the line and dim the hashes")
    func heading() {
        let spans = styled("## Hello")
        #expect(spans.map(\.1) == ["heading2", "syntax"])
        #expect(spans[1].0 == "## ")
    }

    @Test("emphasis dims its markers")
    func emphasis() {
        let spans = styled("a **b** c")
        #expect(spans.contains { $0 == ("**b**", "strong") })
        #expect(spans.filter { $0.1 == "syntax" }.map(\.0) == ["**", "**"])
    }

    @Test("links style the label and dim the brackets and destination")
    func link() {
        let spans = styled("[label](https://x)")
        #expect(spans.contains { $0 == ("label", "link") })
        #expect(spans.filter { $0.1 == "syntax" }.map(\.0) == ["[", "](https://x)"])
        #expect(spans.contains { $0 == ("https://x", "linkDestination") })
    }

    @Test("task items dim the bullet, expose the box and mark done content")
    func tasks() {
        let open = styled("- [ ] write")
        #expect(open.map(\.0) == ["- ", "[ ]"])
        #expect(open.map(\.1) == ["syntax", "taskBox"])
        let done = styled("- [x] wrote")
        #expect(done.map(\.1) == ["syntax", "taskBoxChecked", "taskDone"])
    }

    @Test("quotes style the line, dim the marker and style nested content")
    func quote() {
        let spans = styled("> **hi**")
        #expect(spans.map(\.1) == ["quote", "syntax", "strong", "syntax", "syntax"])
    }

    @Test("decorators see every inline")
    func decorators() {
        struct Shout: StylingRule {
            func spans(for inline: Inline, in text: MarkdownText) -> [StyleSpan] {
                inline.kind == .link ? [StyleSpan(range: inline.range, role: StyleRole("shout"))] : []
            }
        }
        var rules = StyleRuleSet.standard
        rules.decorators = [Shout()]
        let doc = MarkdownParser.standard.parse("x [y](z)")
        #expect(rules.spans(for: doc).contains { $0.role.rawValue == "shout" })
    }
}

@Suite("syntax reveal")
struct SyntaxRevealTests {
    let source = "plain **bold** and [link](u)"

    func revealed(at selection: Range<Int>) -> [String] {
        let doc = MarkdownParser.standard.parse(source)
        let spans = SyntaxReveal.apply(StyleRuleSet.standard.spans(for: doc), selection: selection)
        return spans.filter { $0.role == .syntaxRevealed }.map { doc.text[$0.range] }
    }

    @Test("the cursor inside an element reveals only that element's syntax")
    func inside() {
        #expect(revealed(at: 9..<9) == ["**", "**"])
        #expect(revealed(at: 21..<21) == ["[", "](u)"])
        #expect(revealed(at: 2..<2) == [])
    }

    @Test("touching an element's edge counts as being on it")
    func edges() {
        #expect(revealed(at: 14..<14) == ["**", "**"])
        #expect(revealed(at: 6..<6) == ["**", "**"])
    }

    @Test("a selection spanning elements reveals all of them")
    func spanning() {
        #expect(revealed(at: 8..<22).count == 4)
    }

    @Test("elements inside a concealed range never reveal (a subpage row's line)")
    func concealed() {
        let doc = MarkdownParser.standard.parse(source)
        let spans = SyntaxReveal.apply(StyleRuleSet.standard.spans(for: doc), selection: 0..<28, concealed: [19..<28])
        #expect(spans.filter { $0.role == .syntaxRevealed }.map { doc.text[$0.range] } == ["**", "**"])
    }
}
