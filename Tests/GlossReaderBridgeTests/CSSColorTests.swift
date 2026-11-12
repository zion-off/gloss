import Testing
@testable import GlossReaderBridge

@Suite("css colours")
struct CSSColorTests {
    @Test("hex notations parse into sRGB components")
    func parses() {
        #expect(CSSColor(hex: "#ffffff") == CSSColor(red: 1, green: 1, blue: 1))
        #expect(CSSColor(hex: "#f00") == CSSColor(red: 1, green: 0, blue: 0))
        #expect(CSSColor(hex: " #00000080 ") == CSSColor(red: 0, green: 0, blue: 0, alpha: 128.0 / 255))
        let sepia = CSSColor(hex: "#f8f1e3")
        #expect(sepia?.red == 248.0 / 255 && sepia?.green == 241.0 / 255 && sepia?.blue == 227.0 / 255 && sepia?.alpha == 1)
    }

    @Test("every theme background parses")
    func themes() {
        for theme in ReaderSettings.Theme.allCases {
            let appearance = AppearanceStyler().appearance(for: ReaderSettings(theme: theme))
            #expect(CSSColor(hex: appearance.colors.background) != nil, "\(theme)")
        }
    }

    @Test("anything else is refused")
    func refuses() {
        for text in ["", "#", "ffffff", "#ffff", "#fffffff", "#gggggg", "rgba(0, 0, 0, 1)", "#\u{FF10}\u{FF10}\u{FF10}"] {
            #expect(CSSColor(hex: text) == nil, "\(text)")
        }
    }
}
