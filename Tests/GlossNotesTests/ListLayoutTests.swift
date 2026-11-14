import Testing
import GlossMarkdown
@testable import GlossNotes

@Suite("list layout")
struct ListLayoutTests {
    @Test("levels step one marker column; wrapped lines start where the text does")
    func indents() {
        let lines = ListLayout.lines(in: MarkdownParser.notes.parse("- a\n  - b\n> 1. c"))
        #expect(lines.map(\.level) == [0, 1, 0])
        #expect(lines.map(\.quoted) == [false, false, true])
        let nested = ListLayout.indents(level: 1, markerWidth: 10, bodySize: 16)
        #expect(nested == .init(firstLine: 24, head: 48, gap: 14))
        // A marker wider than the column pushes its text out instead of overlapping it.
        #expect(ListLayout.indents(level: 0, markerWidth: 30, bodySize: 16).head == 30)
    }
}
