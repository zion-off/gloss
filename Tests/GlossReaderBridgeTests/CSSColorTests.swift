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

    @Test("rgba notation parses, with the palette's own values")
    func rgba() {
        #expect(CSSColor(rgba: "rgba(240, 199, 56, 0.35)")
                == CSSColor(red: 240.0 / 255, green: 199.0 / 255, blue: 56.0 / 255, alpha: 0.35))
        #expect(CSSColor(rgba: " rgba( 0,0,0,1 ) ") == CSSColor(red: 0, green: 0, blue: 0, alpha: 1))
        for text in ["rgba(240, 199, 56)", "rgba(260, 0, 0, 0.5)", "rgba(0, 0, 0, 1.5)", "rgb(1, 2, 3)",
                     "rgba(0, 0, 0, 0.35%)", ""] {
            #expect(CSSColor(rgba: text) == nil, "\(text)")
        }
    }

    @Test("every palette colour parses: backgrounds, markers, all five highlights, all themes")
    func wholePalette() {
        for theme in ReaderSettings.Theme.allCases {
            let appearance = AppearanceStyler().appearance(for: ReaderSettings(theme: theme))
            #expect(CSSColor(palette: appearance.colors.background) != nil, "\(theme) background")
            #expect(CSSColor(palette: appearance.colors.foreground) != nil, "\(theme) foreground")
            #expect(CSSColor(palette: appearance.colors.marker) != nil, "\(theme) marker")
            for (name, color) in Mirror(reflecting: appearance.colors.highlights).children {
                #expect(CSSColor(palette: color as? String ?? "") != nil, "\(theme) \(name)")
            }
        }
    }
}

