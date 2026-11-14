import Testing
@testable import GlossMarkdown

@Suite("table styling")
struct TableStylingTests {
    @Test("cell inlines are styled and the source is monospaced with dim pipes and a bold header")
    func styling() {
        let doc = parseNotes("| **a** | b |\n|---|---|\n| [l](https://x) | 2 |")
        let spans = StyleRuleSet.standard.spans(for: doc).map { (doc.text[$0.range], $0.role) }
        #expect(spans.contains { $0.1 == .tableSource && $0.0.hasPrefix("| **a**") })
        #expect(spans.filter { $0.1 == .tableSyntax }.map(\.0) == ["|", "|", "|", "|", "|", "|", "|", "|", "|", "|---|---|"])
        #expect(spans.contains { $0 == ("**a**", .tableHeader) } && spans.contains { $0 == ("b", .tableHeader) })
        #expect(spans.contains { $0 == ("**a**", .strong) } && spans.contains { $0 == ("l", .link) })
        #expect(LinkScanner.links(in: doc).map(\.destination) == ["https://x"])
    }
}
