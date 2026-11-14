import Foundation
import GlossCore

/// The user's reading settings, stored via `SettingsService` under these keys.
public struct ReaderSettings: Hashable, Codable, Sendable {
    /// Books' page colours, in its order.
    public enum Theme: String, CaseIterable, Codable, Sendable {
        case light, sepia, gray, night

        /// Light text on a dark page.
        public var isDark: Bool { self == .gray || self == .night }
    }

    /// Books' typefaces (all ship with macOS). `original` leaves the book's own fonts, over the
    /// system font where it sets none.
    public enum Typeface: String, CaseIterable, Codable, Sendable {
        case original, sanFrancisco, newYork, athelas, charter, georgia, iowan, palatino, seravek, timesNewRoman

        /// The name people see.
        public var label: String {
            switch self {
            case .original: "original"
            case .sanFrancisco: "san francisco"
            case .newYork: "new york"
            case .athelas: "athelas"
            case .charter: "charter"
            case .georgia: "georgia"
            case .iowan: "iowan"
            case .palatino: "palatino"
            case .seravek: "seravek"
            case .timesNewRoman: "times new roman"
            }
        }

        /// The installed family, for typefaces that are one (the system's own two aren't).
        public var familyName: String? {
            switch self {
            case .original, .sanFrancisco, .newYork: nil
            case .athelas: "Athelas"
            case .charter: "Charter"
            case .georgia: "Georgia"
            case .iowan: "Iowan Old Style"
            case .palatino: "Palatino"
            case .seravek: "Seravek"
            case .timesNewRoman: "Times New Roman"
            }
        }

        /// The CSS family list; nil keeps the book's fonts.
        var css: String? {
            switch self {
            case .original: nil
            case .sanFrancisco: "-apple-system, system-ui, sans-serif"
            case .newYork: "ui-serif, Georgia, serif"
            case .seravek: "Seravek, -apple-system, sans-serif"
            default: familyName.map { "'\($0)', Georgia, serif" }
            }
        }
    }

    public var theme: Theme
    public var typeface: Typeface
    /// Night while the Mac is in dark mode, whatever `theme` is (Books' auto-night).
    public var autoNight: Bool
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
                flow: ReaderFlow = .paginated, margin: Int = 48, maxInlineSize: Int = 720, maxColumnCount: Int = 2,
                autoNight: Bool = false, typeface: Typeface = .original) {
        self.theme = theme
        self.typeface = typeface
        self.autoNight = autoNight
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.flow = flow
        self.margin = margin
        self.maxInlineSize = maxInlineSize
        self.maxColumnCount = maxColumnCount
    }

    /// Settings stored before a field existed read it as its default, not as unreadable (which
    /// would throw every other stored setting away).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decode(Theme.self, forKey: .theme)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        lineHeight = try container.decode(Double.self, forKey: .lineHeight)
        flow = try container.decode(ReaderFlow.self, forKey: .flow)
        margin = try container.decode(Int.self, forKey: .margin)
        maxInlineSize = try container.decode(Int.self, forKey: .maxInlineSize)
        maxColumnCount = try container.decode(Int.self, forKey: .maxColumnCount)
        autoNight = try container.decodeIfPresent(Bool.self, forKey: .autoNight) ?? false
        typeface = try container.decodeIfPresent(Typeface.self, forKey: .typeface) ?? .original
    }

    /// The theme a book shows in: night while the system is dark and auto-night is on, else `theme`.
    public func theme(systemIsDark: Bool) -> Theme {
        autoNight && systemIsDark ? .night : theme
    }

    public static let settingKey = SettingKey<Data>("reader.settings", default: Data())
}

/// Turns reading settings into the appearance payload the reader applies.
public struct AppearanceStyler: Sendable {
    public init() {}

    /// `systemIsDark`: whether the Mac is in dark mode, which auto-night follows.
    public func appearance(for settings: ReaderSettings, systemIsDark: Bool = false) -> ReaderAppearance {
        let theme = settings.theme(systemIsDark: systemIsDark)
        let palette = Palette.for(theme)
        let dark = theme.isDark
        // One page colour: the theme's background on `html` only, which paints the whole
        // section document and is what foliate copies to its margins; book backgrounds on `body`
        // would paint just the column boxes, so they go. Text takes the theme colour; a dark
        // theme also overrides the book's own text and box colours, which assume a light page.
        let css = """
        :root { color-scheme: \(dark ? "dark" : "light"); }
        html { color: \(palette.foreground) !important; background: \(palette.background) !important; }
        body { color: inherit !important; background: transparent !important;
               font-size: \(Self.number(settings.fontSize))px; line-height: \(Self.number(settings.lineHeight));
               font-family: \(palette.fontFamily); }\(dark ? "\nbody * { color: inherit !important; background-color: transparent !important; }" : "")\(Self.typefaceRule(settings.typeface))
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
                                 marker: palette.marker, highlights: Self.pageHighlights(for: theme),
                                 search: Self.searchHighlights(for: theme)))
    }

    /// A search session's shades: the macOS find-highlight yellow, tuned per theme's paper —
    /// soft for the matches around, stronger for the one being read.
    public static func searchHighlights(for theme: ReaderSettings.Theme) -> ReaderColors.Search {
        switch theme {
        case .light: .init(soft: "rgba(255, 214, 10, 0.22)", current: "rgba(255, 214, 10, 0.55)")
        case .sepia: .init(soft: "rgba(255, 200, 0, 0.2)", current: "rgba(255, 200, 0, 0.5)")
        case .gray: .init(soft: "rgba(255, 214, 10, 0.22)", current: "rgba(255, 214, 10, 0.5)")
        case .night: .init(soft: "rgba(255, 214, 10, 0.2)", current: "rgba(255, 214, 10, 0.5)")
        }
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
        case .gray:
            .init(yellow: "rgba(255, 214, 10, 0.3)", green: "rgba(48, 209, 88, 0.3)",
                  blue: "rgba(64, 156, 255, 0.34)", pink: "rgba(255, 55, 135, 0.3)",
                  purple: "rgba(191, 90, 242, 0.34)")
        case .night:
            .init(yellow: "rgba(255, 214, 10, 0.28)", green: "rgba(48, 209, 88, 0.26)",
                  blue: "rgba(64, 156, 255, 0.3)", pink: "rgba(255, 55, 135, 0.28)",
                  purple: "rgba(191, 90, 242, 0.3)")
        }
    }

    /// A chosen typeface over the book's own fonts, everywhere but code, which stays monospaced.
    static func typefaceRule(_ typeface: ReaderSettings.Typeface) -> String {
        guard let family = typeface.css else { return "" }
        return "\nbody, body :not(pre, code, kbd, samp, tt, pre *) { font-family: \(family) !important; }"
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
            case .gray:
                Palette(foreground: "#e5e5e7", background: "#4a4a4d", marker: "rgba(229, 229, 231, 0.5)",
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
