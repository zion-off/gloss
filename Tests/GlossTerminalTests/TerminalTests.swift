import Testing
@testable import GlossTerminal

@Suite("terminal")
struct TerminalTests {
    let color = Terminal(colorEnabled: true, isTTY: true, width: 40)

    @Test("colour policy: NO_COLOR wins, then CLICOLOR_FORCE, then TERM=dumb, then the tty")
    func policy() {
        #expect(Terminal.colorPolicy(isTTY: true, environment: [:]))
        #expect(!Terminal.colorPolicy(isTTY: false, environment: [:]))
        #expect(!Terminal.colorPolicy(isTTY: true, environment: ["NO_COLOR": "1"]))
        #expect(!Terminal.colorPolicy(isTTY: true, environment: ["NO_COLOR": "1", "CLICOLOR_FORCE": "1"]))
        #expect(Terminal.colorPolicy(isTTY: true, environment: ["NO_COLOR": ""]))
        #expect(Terminal.colorPolicy(isTTY: false, environment: ["CLICOLOR_FORCE": "1"]))
        #expect(!Terminal.colorPolicy(isTTY: false, environment: ["CLICOLOR_FORCE": "0"]))
        #expect(!Terminal.colorPolicy(isTTY: true, environment: ["TERM": "dumb"]))
    }

    @Test("painting adds escape codes only when colours are on")
    func paint() {
        #expect(color.paint("hi", .title) == "\u{1B}[1;38;5;212mhi\u{1B}[0m")
        #expect(Terminal.plain.paint("hi", .title) == "hi")
        #expect(color.paint("hi", .plain) == "hi")
        #expect(color.paint("", .title) == "")
    }

    @Test("display width counts wide characters, emoji and combining marks")
    func width() {
        #expect(DisplayWidth.of("abc") == 3)
        #expect(DisplayWidth.of("日本") == 4)
        #expect(DisplayWidth.of("🌙x") == 3)
        #expect(DisplayWidth.of("e\u{301}") == 1)
        #expect(DisplayWidth.of(color.paint("pink", .title)) == 4)
        #expect(DisplayWidth.truncate("abcdefgh", to: 5) == "abcd…")
        #expect(DisplayWidth.truncate("日本語です", to: 5) == "日本…")
        #expect(DisplayWidth.truncate("short", to: 10) == "short")
        #expect(DisplayWidth.pad("日", to: 4) == "日  ")
    }

    @Test("tables align columns and shrink flexible ones to fit")
    func table() {
        let table = TerminalTable(
            columns: [.init("title", flexible: true), .init("pages", alignRight: true)],
            rows: [["The Myth of Sisyphus and Other Essays", "212"], ["Caligula", "88"]])
        #expect(table.render(on: Terminal(colorEnabled: false, isTTY: false, width: 80)) == """
        title                                  pages
        The Myth of Sisyphus and Other Essays    212
        Caligula                                  88
        """)
        let narrow = table.render(on: Terminal(colorEnabled: false, isTTY: false, width: 24))
        #expect(narrow.split(separator: "\n").allSatisfy { DisplayWidth.of($0) <= 24 })
        #expect(narrow.contains("…"))
    }

    @Test("trees draw branches")
    func tree() {
        let tree = TerminalTree(root: .init(label: "book", children: [
            .init(label: "a", detail: "2 lines", children: [.init(label: "a1")]),
            .init(label: "b"),
        ]))
        #expect(tree.render(on: .plain) == """
        book
        ├─ a  2 lines
        │  └─ a1
        └─ b
        """)
    }

    @Test("text wraps on word boundaries with an indent")
    func wrap() {
        #expect(TextWrap.wrap("one must imagine sisyphus happy", width: 16, indent: "  ")
                == ["  one must", "  imagine", "  sisyphus happy"])
    }
}
