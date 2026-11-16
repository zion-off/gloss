import Testing
import GlossMarkdown
@testable import GlossNotes

@Suite("notes spelling")
struct NotesSpellingTests {
    /// The skipped text of a page, as the user wrote it.
    func skipped(_ markdown: String) -> [String] {
        let document = MarkdownParser.notes.parse(markdown)
        let spans = NotesStyler().spans(for: document)
        let units = Array(markdown.utf16)
        return NotesSpelling.standard.skippedRanges(in: spans).map { String(decoding: units[$0], as: UTF16.self) }
    }

    @Test("code, link destinations and syntax are skipped; words around them are not")
    func skipsCodeLinksAndSyntax() {
        #expect(skipped("teh `teh` teh") == ["`teh`"])
        #expect(skipped("see [teh](https://example.com/teh) ok") == ["[", "](https://example.com/teh)"])
        #expect(skipped("**teh**") == ["**", "**"])
        #expect(skipped("```\nfnord\n```\nteh") == ["```\nfnord\n```"])
        #expect(skipped("just words") == [])
    }

    @Test("drawn tables and subpage rows are skipped")
    func skipsDrawnText() {
        let spans = [StyleSpan(range: 0..<10, role: NotesRole.tableGrid), StyleSpan(range: 20..<30, role: NotesRole.subpageBlock),
                     StyleSpan(range: 5..<15, role: .code), StyleSpan(range: 40..<45, role: .strong)]
        #expect(NotesSpelling.standard.skippedRanges(in: spans) == [0..<15, 20..<30])
    }

    @Test("a result is skipped when it touches a skipped range")
    func overlap() {
        let skipped = [2..<4, 10..<20]
        #expect(NotesSpelling.isSkipped(3..<8, in: skipped))
        #expect(NotesSpelling.isSkipped(0..<3, in: skipped))
        #expect(NotesSpelling.isSkipped(12..<14, in: skipped))
        #expect(!NotesSpelling.isSkipped(4..<10, in: skipped))
        #expect(!NotesSpelling.isSkipped(0..<2, in: skipped))
        #expect(!NotesSpelling.isSkipped(20..<25, in: skipped))
        #expect(NotesSpelling.isSkipped(15..<15, in: skipped))
        #expect(!NotesSpelling.isSkipped(4..<10, in: []))
    }
}
