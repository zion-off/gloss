import Testing
@testable import GlossCore

@Suite("text matcher")
struct TextMatcherTests {
    @Test("matching is prefix-based, case- and diacritic-insensitive, all words required")
    func matching() {
        let matcher = TextMatcher(query: "Cafe soci")
        #expect(matcher.matches("Le Café Society"))
        #expect(!matcher.matches("Le Café only"))
        #expect(!TextMatcher(query: "  ").matches("anything"))
    }

    @Test("first match is reported in UTF-16 units")
    func utf16() {
        let matcher = TextMatcher(query: "night")
        #expect(matcher.firstMatchUTF16(in: "🌙 tender is the night") == 17..<22)
    }

    @Test("snippets mark matching words and elide long context")
    func snippet() {
        let text = (1...30).map { "w\($0)" }.joined(separator: " ") + " target " + (31...60).map { "w\($0)" }.joined(separator: " ")
        let snippet = TextMatcher(query: "targ").snippet(of: text, radius: 2)
        #expect(snippet.plainText == "…w29 w30 target w31 w32…")
        #expect(snippet.segments.filter(\.isMatch).map(\.text) == ["target"])
    }
}
