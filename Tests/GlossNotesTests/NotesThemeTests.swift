import Testing
import GlossCore
import GlossMarkdown
@testable import GlossNotes

@Suite("notes theme")
struct NotesThemeTests {
    let theme = NotesTheme.standard

    func runs(_ text: String, selection: Range<Int> = 0..<0, styler: NotesStyler = NotesStyler()) -> [StyledRun] {
        let document = MarkdownParser.standard.parse(text)
        let spans = SyntaxReveal.apply(styler.spans(for: document), selection: selection)
        return theme.runs(for: spans, length: text.utf16.count)
    }

    func style(at offset: Int, in runs: [StyledRun]) -> TextStyle? {
        runs.first { $0.range.contains(offset) }?.style
    }

    @Test("runs cover the text exactly, without gaps or overlaps")
    func coverage() {
        for text in ["", "plain", "# a **b** _c_ `d`\n> quote [l](https://x.y)\n- [x] done\n\n```\ncode\n```", "**unclosed"] {
            let result = runs(text)
            let length = text.utf16.count
            #expect(result.first?.range.lowerBound ?? 0 == 0, "\(text)")
            #expect(result.last?.range.upperBound ?? 0 == length, "\(text)")
            for (a, b) in zip(result, result.dropFirst()) {
                #expect(a.range.upperBound == b.range.lowerBound, "\(text)")
                #expect(a.style != b.style, "neighbours with equal styles merge: \(text)")
            }
        }
    }

    @Test("layers combine: dimmed syntax inside a heading keeps the heading font")
    func layering() {
        let text = "# a **bold** word"
        let result = runs(text, selection: 0..<0)
        let star = style(at: 4, in: result)  // the first `*`
        #expect(star?.font == .heading(1) && star?.bold == true && star?.color == .tertiary)
        let bold = style(at: 7, in: result)
        #expect(bold?.font == .heading(1) && bold?.bold == true && bold?.color == nil)
    }

    @Test("the cursor reveals syntax at full strength")
    func revealed() {
        let text = "a **bold** word"
        #expect(style(at: 2, in: runs(text))?.color == .tertiary)
        #expect(style(at: 2, in: runs(text, selection: 5..<5))?.color == nil)
    }

    @Test("gloss links are styled by kind and status")
    func links() {
        let page = GlossLink.page(PageID(GlossID(high: 1, low: 1)))
        let gone = GlossLink.page(PageID(GlossID(high: 1, low: 2)))
        let text = "[a](\(page)) [b](\(gone))"
        let styler = NotesStyler(statuses: [page: .live, gone: .missing])
        let result = runs(text, styler: styler)
        #expect(style(at: 1, in: result)?.color == .link)
        let brokenStart = text.utf16.count - "b](\(gone))".utf16.count
        #expect(style(at: brokenStart, in: result)?.color == .warning)
    }

    @Test("blocks: quotes and code mark their lines; tasks and subpage lines")
    func blocks() {
        let quote = runs("> said")
        #expect(style(at: 3, in: quote)?.block == .quote && style(at: 3, in: quote)?.color == .secondary)
        let code = runs("```\nlet x\n```")
        #expect(style(at: 5, in: code)?.block == .code && style(at: 5, in: code)?.font == .monospaced)
        let task = runs("- [x] done")
        #expect(style(at: 7, in: task)?.strikethrough == true)
    }

    @Test("unknown roles and empty or out-of-range spans are ignored")
    func robustness() {
        let spans = [StyleSpan(range: 0..<3, role: StyleRole("mystery")), StyleSpan(range: 2..<2, role: .strong),
                     StyleSpan(range: -5..<2, role: .emphasis), StyleSpan(range: 3..<99, role: .strong)]
        let result = theme.runs(for: spans, length: 5)
        #expect(result == [StyledRun(range: 0..<2, style: TextStyle(italic: true)), StyledRun(range: 2..<3, style: TextStyle()),
                           StyledRun(range: 3..<5, style: TextStyle(bold: true))])
        #expect(theme.runs(for: spans, length: 0).isEmpty)
    }

    @Test("a selection move only changes the revealed syntax")
    func diff() {
        let text = "a **bold** and _it_ end"
        let before = runs(text, selection: 0..<0)
        let after = runs(text, selection: 5..<5)
        #expect(StyledRunDiff.changedRanges(from: before, to: after) == [2..<4, 8..<10])
        #expect(StyledRunDiff.changedRanges(from: before, to: before).isEmpty)
        #expect(StyledRunDiff.changedRanges(from: before, to: runs(text + "!")) == [0..<(text.utf16.count + 1)])
        #expect(StyledRunDiff.changedRanges(from: [], to: []).isEmpty)
    }
}
