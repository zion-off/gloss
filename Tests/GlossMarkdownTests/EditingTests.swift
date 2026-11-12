import Testing
@testable import GlossMarkdown

/// Runs a command on text where `|` marks the cursor or `‹…›` marks a selection, and returns
/// the result in the same notation.
func run(_ command: any MarkdownEditCommand, _ marked: String) -> String? {
    let (text, selection) = unmark(marked)
    guard let result = command.edit(MarkdownParser.standard.parse(text), selection: selection) else { return nil }
    return mark(result.apply(to: text), result.selection)
}

func unmark(_ marked: String) -> (String, Range<Int>) {
    var units = Array(marked.utf16)
    if let bar = units.firstIndex(of: 0x7C) {
        units.remove(at: bar)
        return (String(decoding: units, as: UTF16.self), bar..<bar)
    }
    let open = units.firstIndex(of: Array("‹".utf16)[0])!
    units.remove(at: open)
    let close = units.firstIndex(of: Array("›".utf16)[0])!
    units.remove(at: close)
    return (String(decoding: units, as: UTF16.self), open..<close)
}

func mark(_ text: String, _ selection: Range<Int>) -> String {
    var units = Array(text.utf16)
    if selection.isEmpty {
        units.insert(0x7C, at: selection.lowerBound)
    } else {
        units.insert(Array("›".utf16)[0], at: selection.upperBound)
        units.insert(Array("‹".utf16)[0], at: selection.lowerBound)
    }
    return String(decoding: units, as: UTF16.self)
}

@Suite("edit results")
struct EditResultTests {
    @Test("offsets map through insertions according to affinity")
    func mapping() {
        let edits = [TextEdit.insert("**", at: 2), TextEdit.insert("**", at: 5)]
        #expect(EditResult.map(2, through: edits, afterInsertions: true) == 4)
        #expect(EditResult.map(2, through: edits, afterInsertions: false) == 2)
        #expect(EditResult.map(5, through: edits, afterInsertions: false) == 7)
        #expect(EditResult.map(9, through: edits, afterInsertions: false) == 13)
    }

    @Test("coalescing yields one equivalent replacement")
    func coalesce() {
        let text = "hello world"
        let result = EditResult(edits: [.insert("*", at: 0), .delete(5..<6), .insert("*", at: 11)], selection: 0..<0)
        let single = result.coalesced(in: text)!
        let applied = EditResult(edits: [single], selection: 0..<0).apply(to: text)
        #expect(applied == result.apply(to: text))
        #expect(applied == "*helloworld*")
    }
}

@Suite("inline formatting")
struct InlineFormattingTests {
    @Test("wrapping a selection keeps the text selected")
    func wrap() {
        #expect(run(ToggleInline.bold, "a ‹big› deal") == "a **‹big›** deal")
        #expect(run(ToggleInline.italic, "‹x›") == "*‹x›*")
        #expect(run(ToggleInline.code, "use ‹ls -la› here") == "use `‹ls -la›` here")
        #expect(run(ToggleInline.strikethrough, "‹no›") == "~~‹no›~~")
    }

    @Test("selections are trimmed so markers hug the text")
    func trims() {
        #expect(run(ToggleInline.bold, "a‹ big ›deal") == "a **‹big›** deal")
    }

    @Test("toggling inside an existing span removes it")
    func unwrap() {
        #expect(run(ToggleInline.bold, "a **b|ig** deal") == "a b|ig deal")
        #expect(run(ToggleInline.bold, "a **‹big›** deal") == "a ‹big› deal")
        #expect(run(ToggleInline.italic, "*‹x›*") == "‹x›")
    }

    @Test("an empty selection wraps the word or inserts a pair")
    func emptySelection() {
        #expect(run(ToggleInline.bold, "wo|rd") == "**wo|rd**")
        #expect(run(ToggleInline.bold, "a | b") == "a **|** b")
    }

    @Test("same-kind spans inside the selection are absorbed")
    func absorb() {
        #expect(run(ToggleInline.bold, "‹a **b** c›") == "**‹a b c›**")
    }

    @Test("multi-line selections wrap each line's content, skipping markers and blanks")
    func multiLine() {
        #expect(run(ToggleInline.bold, "- ‹one\n\n- two›") == "- **‹one**\n\n- **two›**")
        #expect(run(ToggleInline.italic, "## ‹Title›") == "## *‹Title›*")
    }

    @Test("isActive reflects the span under the selection")
    func active() {
        let doc = MarkdownParser.standard.parse("a **bold** b")
        #expect(ToggleInline.bold.isActive(doc, selection: 5..<5))
        #expect(!ToggleInline.bold.isActive(doc, selection: 0..<0))
        #expect(!ToggleInline.italic.isActive(doc, selection: 5..<5))
    }
}

@Suite("block formatting")
struct BlockFormattingTests {
    @Test("headings set, change and toggle off")
    func headings() {
        #expect(run(ToggleHeading(level: 2), "tit|le") == "## tit|le")
        #expect(run(ToggleHeading(level: 2), "# tit|le") == "## tit|le")
        #expect(run(ToggleHeading(level: 2), "## tit|le") == "tit|le")
        #expect(run(ToggleHeading(level: 1), "- it|em") == "# it|em")
        #expect(run(ToggleHeading(level: 1), "> quo|te") == "> # quo|te")
        #expect(run(ToggleHeading(level: 3), "|") == "### |")
    }

    @Test("lists set, switch style, keep indentation and toggle off")
    func lists() {
        #expect(run(ToggleList(.bullet), "‹a\nb›") == "- ‹a\n- b›")
        #expect(run(ToggleList(.ordered), "‹a\n\nb›") == "1. ‹a\n\n2. b›")
        #expect(run(ToggleList(.task), "  - it|em") == "  - [ ] it|em")
        #expect(run(ToggleList(.bullet), "- ‹a\n- b›") == "‹a\nb›")
        #expect(run(ToggleList(.bullet), "# he|ad") == "- he|ad")
        #expect(run(ToggleList(.bullet), "|") == "- |")
    }

    @Test("quotes add and remove one level")
    func quotes() {
        #expect(run(ToggleQuote(), "‹a\nb›") == "> ‹a\n> b›")
        #expect(run(ToggleQuote(), "> ‹a\n> b›") == "‹a\nb›")
        #expect(run(ToggleQuote(), "> > dee|p") == "> dee|p")
    }

    @Test("code adapts: inline within a line, fenced across lines")
    func code() {
        #expect(run(ToggleCode(), "run ‹this›") == "run `‹this›`")
        #expect(run(ToggleCode(), "‹a\nb›") == "```\n‹a\nb›\n```")
        #expect(run(ToggleCode(), "```\nco|de\n```") == "co|de")
    }

    @Test("dividers go on their own line")
    func divider() {
        #expect(run(InsertDivider(), "|") == "---\n|")
        #expect(run(InsertDivider(), "te|xt") == "text\n---\n|")
    }
}

@Suite("list editing")
struct ListEditingTests {
    func enter(_ marked: String) -> String? {
        let (text, selection) = unmark(marked)
        guard let result = ListContinuation.newline(in: MarkdownParser.standard.parse(text), selection: selection) else { return nil }
        return mark(result.apply(to: text), result.selection)
    }

    @Test("return continues bullets, numbers, tasks and quotes")
    func continues() {
        #expect(enter("- one|") == "- one\n- |")
        #expect(enter("* one|") == "* one\n* |")
        #expect(enter("9. nine|") == "9. nine\n10. |")
        #expect(enter("1) a|") == "1) a\n2) |")
        #expect(enter("- [x] done|") == "- [x] done\n- [ ] |")
        #expect(enter("  - nested|") == "  - nested\n  - |")
        #expect(enter("> quoted|") == "> quoted\n> |")
        #expect(enter("> - item|") == "> - item\n> - |")
    }

    @Test("return splits an item at the cursor")
    func splits() {
        #expect(enter("- ab|cd") == "- ab\n- |cd")
    }

    @Test("return on an empty item ends or outdents it")
    func ends() {
        #expect(enter("- one\n- |") == "- one\n|")
        #expect(enter("  - |") == "- |")
        #expect(enter("> |") == "|")
    }

    @Test("plain lines and code get a normal newline")
    func passthrough() {
        #expect(enter("text|") == nil)
        #expect(enter("```\n- not a list|\n```") == nil)
        #expect(enter("-| item") == nil)
    }

    @Test("tab indents and shift-tab outdents list items only")
    func indentation() {
        let (text, selection) = unmark("- it|em")
        let doc = MarkdownParser.standard.parse(text)
        let indented = ListIndentation.indent(in: doc, selection: selection)!
        #expect(mark(indented.apply(to: text), indented.selection) == "  - it|em")
        let back = "  - it|em"
        let (t2, s2) = unmark(back)
        let outdented = ListIndentation.outdent(in: MarkdownParser.standard.parse(t2), selection: s2)!
        #expect(mark(outdented.apply(to: t2), outdented.selection) == "- it|em")
        #expect(ListIndentation.indent(in: MarkdownParser.standard.parse("plain"), selection: 0..<0) == nil)
    }

    @Test("task boxes toggle")
    func tasks() {
        let doc = MarkdownParser.standard.parse("- [ ] write\n- [x] read")
        #expect(TaskToggle.toggle(in: doc, at: 3)?.apply(to: doc.text.string) == "- [x] write\n- [x] read")
        #expect(TaskToggle.toggle(in: doc, at: 15)?.apply(to: doc.text.string) == "- [ ] write\n- [ ] read")
        #expect(TaskToggle.boxRange(in: doc, at: 0) == 2..<5)
        #expect(TaskToggle.toggle(in: MarkdownParser.standard.parse("- plain"), at: 1) == nil)
    }
}

@Suite("link editing")
struct LinkEditingTests {
    let url = "gloss://passage/0000000000000000000000000a"

    @Test("wrapping makes a link and keeps the label selected")
    func wrap() {
        #expect(run(WrapInLink(destination: url), "see ‹this bit› here") == "see [‹this bit›](\(url)) here")
    }

    @Test("stray brackets in the label are escaped")
    func escapesBrackets() {
        #expect(run(WrapInLink(destination: "u"), "‹a [b] c›") == "[‹a \\[b\\] c›](u)")
    }

    @Test("selecting inside a link retargets it")
    func retarget() {
        #expect(run(WrapInLink(destination: "new"), "[la‹be›l](old)") == "[‹label›](new)")
    }

    @Test("wrapping is refused across lines, in code and across link edges")
    func refused() {
        let doc = MarkdownParser.standard.parse("a\nb `code` [x](y)")
        #expect(!WrapInLink.canWrap(doc, selection: 0..<3))
        #expect(!WrapInLink.canWrap(doc, selection: 0..<0))
        #expect(!WrapInLink.canWrap(doc, selection: 5..<8))
        #expect(!WrapInLink.canWrap(doc, selection: 11..<14))
        #expect(WrapInLink.canWrap(doc, selection: 2..<3))
    }

    @Test("destinations with spaces are bracketed")
    func destinations() {
        #expect(MarkdownEscaping.escapeDestination("a b") == "<a b>")
        #expect(MarkdownEscaping.escapeDestination("x(1)") == "x(1)")
        #expect(MarkdownEscaping.escapeDestination("x)") == "<x)>")
    }

    @Test("the link template puts the cursor where the user types next")
    func template() {
        #expect(run(InsertLinkTemplate(), "‹word›") == "[word](|)")
        #expect(run(InsertLinkTemplate(), "a | b") == "a [|]() b")
    }
}

@Suite("escaping and links")
struct EscapingTests {
    @Test("inline escaping neutralises syntax but leaves words readable")
    func inline() {
        #expect(MarkdownEscaping.escapeInline("a *b* [c]") == "a \\*b\\* \\[c\\]")
        #expect(MarkdownEscaping.escapeInline("snake_case _em_") == "snake_case \\_em\\_")
        #expect(MarkdownEscaping.escapeInline("# not heading") == "\\# not heading")
        #expect(MarkdownEscaping.escapeInline("1. not a list") == "1\\. not a list")
        #expect(MarkdownEscaping.escapeInline("x < y <b>") == "x < y \\<b>")
    }

    @Test("escaped text parses back to the same plain text")
    func roundTrip() {
        for sample in ["a *b* _c_ `d` [e](f) ~~g~~ \\h", "# x", "- y", "> z"] {
            let escaped = MarkdownEscaping.escapeInline(sample)
            let doc = MarkdownParser.standard.parse("> " + escaped)
            let inner = doc.blocks[0].children[0]
            #expect(inner.kind == .paragraph, "\(sample)")
            #expect(PlainText.strip(doc.text[inner.contentRange]) == sample)
        }
    }

    @Test("links are found outside code and can be rewritten")
    func scanning() {
        let source = "[a](gloss://page/x) `[b](c)`\n```\n[d](e)\n```\n<https://f>"
        let links = LinkScanner.links(in: source)
        #expect(links.map(\.destination) == ["gloss://page/x", "https://f"])
        let rewritten = LinkScanner.rewrite(source) { $0.destination.hasPrefix("gloss:") ? $0.label : nil }
        #expect(rewritten == "a `[b](c)`\n```\n[d](e)\n```\n<https://f>")
    }

    @Test("plain text strips inline syntax")
    func plain() {
        #expect(PlainText.strip("**bold** and [link](u) and \\*") == "bold and link and *")
    }
}
