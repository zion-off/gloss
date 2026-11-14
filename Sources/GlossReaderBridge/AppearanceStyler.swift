import Foundation
import GlossCore

/// The user's reading settings, stored via `SettingsService` under these keys.
public struct ReaderSettings: Hashable, Codable, Sendable {
    public enum Theme: String, CaseIterable, Codable, Sendable {
        case light, sepia, night
    }

    public var theme: Theme
    /// Body text size in px.
    public var fontSize: Double
    public var lineHeight: Double
    public var flow: ReaderFlow
    /// Page margin in px.
    public var margin: Int
    /// Widest a column of text may be, in px.
    public var maxInlineSize: Int
    /// Columns per page in paginated flow.
    public var maxColumnCount: Int

    public init(theme: Theme = .sepia, fontSize: Double = 17, lineHeight: Double = 1.6,
                flow: ReaderFlow = .paginated, margin: Int = 48, maxInlineSize: Int = 720, maxColumnCount: Int = 2) {
        self.theme = theme
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.flow = flow
        self.margin = margin
        self.maxInlineSize = maxInlineSize
        self.maxColumnCount = maxColumnCount
    }

    public static let settingKey = SettingKey<Data>("reader.settings", default: Data())
}

/// Turns reading settings into the appearance payload the reader applies.
public struct AppearanceStyler: Sendable {
    public init() {}

    public func appearance(for settings: ReaderSettings) -> ReaderAppearance {
        let palette = Palette.for(settings.theme)
        let dark = settings.theme == .night
        // One page colour: the theme's background on `html` only, which paints the whole
        // section document and is what foliate copies to its margins; book backgrounds on `body`
        // would paint just the column boxes, so they go. Text takes the theme colour; a dark
        // theme also overrides the book's own text and box colours, which assume a light page.
        let css = """
        :root { color-scheme: \(dark ? "dark" : "light"); }
        html { color: \(palette.foreground) !important; background: \(palette.background) !important; }
        body { color: inherit !important; background: transparent !important;
               font-size: \(Self.number(settings.fontSize))px; line-height: \(Self.number(settings.lineHeight));
               font-family: \(palette.fontFamily); }\(dark ? "\nbody * { color: inherit !important; background-color: transparent !important; }" : "")
        p, li { text-align: justify; }
        a { color: inherit; }
        img, svg { max-width: 100%; }
        """
        return ReaderAppearance(
            flow: settings.flow,
            css: css,
            layout: ReaderLayout(margin: settings.margin, gap: 0.06, maxInlineSize: settings.maxInlineSize,
                                  maxColumnCount: settings.maxColumnCount),
            colors: ReaderColors(background: palette.background, foreground: palette.foreground,
                                 marker: palette.marker, highlights: Self.pageHighlights(for: settings.theme)))
    }

    /// How the five highlight colours are painted on a theme's page, one row per theme. The picker's
    /// swatches never change; on the page each colour gets a shade tuned for that paper, drawn
    /// as is (normal blending, this alpha) over the text: soft on white rather than neon, clear of
    /// the sepia paper's own yellow (cooler, a touch more saturated) rather than muddy, and dark
    /// but distinct on night so its light text keeps its contrast. A new theme adds a row here.
    public static func pageHighlights(for theme: ReaderSettings.Theme) -> ReaderColors.Highlights {
        switch theme {
        case .light:
            .init(yellow: "rgba(255, 214, 10, 0.32)", green: "rgba(52, 199, 89, 0.24)",
                  blue: "rgba(10, 132, 255, 0.2)", pink: "rgba(255, 55, 135, 0.2)",
                  purple: "rgba(175, 82, 222, 0.2)")
        case .sepia:
            .init(yellow: "rgba(255, 200, 0, 0.3)", green: "rgba(40, 180, 90, 0.24)",
                  blue: "rgba(0, 122, 255, 0.2)", pink: "rgba(240, 60, 120, 0.2)",
                  purple: "rgba(160, 80, 220, 0.2)")
        case .night:
            .init(yellow: "rgba(255, 214, 10, 0.28)", green: "rgba(48, 209, 88, 0.26)",
                  blue: "rgba(64, 156, 255, 0.3)", pink: "rgba(255, 55, 135, 0.28)",
                  purple: "rgba(191, 90, 242, 0.3)")
        }
    }

    /// "19" not "19.0" (CSS does not care, people do).
    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(value)
    }

    struct Palette {
        let foreground: String
        let background: String
        let marker: String
        let fontFamily: String

        static func `for`(_ theme: ReaderSettings.Theme) -> Palette {
            switch theme {
            case .light:
                Palette(foreground: "#1d1d1f", background: "#ffffff", marker: "rgba(29, 29, 31, 0.4)",
                        fontFamily: "-apple-system, 'Iowan Old Style', Georgia, serif")
            case .sepia:
                Palette(foreground: "#3b2f1e", background: "#f8f1e3", marker: "rgba(59, 47, 30, 0.45)",
                        fontFamily: "-apple-system, 'Iowan Old Style', Georgia, serif")
            case .night:
                Palette(foreground: "#d8d8dc", background: "#1c1c1e", marker: "rgba(216, 216, 220, 0.5)",
                        fontFamily: "-apple-system, 'Iowan Old Style', Georgia, serif")
            }
        }
    }
}

/// Stores and loads reader settings as JSON in the settings store.
public struct ReaderSettingsStore: Sendable {
    let settings: SettingsService
    let defaults: ReaderSettings

    public init(settings: SettingsService, defaults: ReaderSettings = ReaderSettings()) {
        self.settings = settings
        self.defaults = defaults
    }

    public func load() async throws -> ReaderSettings {
        let data = try await settings.value(ReaderSettings.settingKey)
        guard !data.isEmpty else { return defaults }
        return (try? JSONDecoder().decode(ReaderSettings.self, from: data)) ?? defaults
    }

    public func save(_ readerSettings: ReaderSettings) async throws {
        try await settings.set(try JSONEncoder().encode(readerSettings), for: ReaderSettings.settingKey)
    }
}
