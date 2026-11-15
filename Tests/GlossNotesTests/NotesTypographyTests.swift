import Testing
@testable import GlossNotes

@Suite("notes typography")
struct NotesTypographyTests {
    @Test("body and code lines are 1.5 times their size, headings 1.3, as in Notion")
    func lineHeights() {
        #expect(NotesTypography.lineHeight(for: .body, fontSize: 16) == 24)
        #expect(NotesTypography.lineHeight(for: .monospaced, fontSize: 14) == 21)
        #expect(NotesTypography.lineHeight(for: .heading(1), fontSize: 30) == 39)
        #expect(NotesTypography.lineHeight(for: .heading(2), fontSize: 24) == 31)
        #expect(NotesTypography.lineHeight(for: .heading(3), fontSize: 20) == 26)
    }

    @Test("inline code rides on its paragraph's line; a code block keeps its own")
    func lineRole() {
        #expect(NotesTypography.lineRole(for: TextStyle(font: .monospaced)) == .body)
        #expect(NotesTypography.lineRole(for: TextStyle(font: .monospaced, block: .code)) == .monospaced)
        #expect(NotesTypography.lineRole(for: TextStyle(font: .heading(2))) == .heading(2))
        #expect(NotesTypography.lineRole(for: TextStyle()) == .body)
    }
}
