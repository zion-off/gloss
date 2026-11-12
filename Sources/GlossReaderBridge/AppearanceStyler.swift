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
        let css = """
        :root { color-scheme: \(settings.theme == .night ? "dark" : "light"); }
        html { color: \(palette.foreground); background: \(palette.background); }
        body { font-size: \(Self.number(settings.fontSize))px; line-height: \(Self.number(settings.lineHeight));
               font-family: \(palette.fontFamily); }
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
                                 marker: palette.marker, highlights: palette.highlights))
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
        let highlights: ReaderColors.Highlights

        static func `for`(_ theme: ReaderSettings.Theme) -> Palette {
            switch theme {
            case .light:
                Palette(foreground: "#1d1d1f", background: "#ffffff", marker: "rgba(29, 29, 31, 0.4)",
                        fontFamily: "-apple-system, 'Iowan Old Style', Georgia, serif",
                        highlights: .init(yellow: "rgba(240, 199, 56, 0.35)", green: "rgba(98, 165, 122, 0.35)",
                                          blue: "rgba(96, 138, 188, 0.35)", pink: "rgba(216, 128, 149, 0.35)",
                                          purple: "rgba(154, 111, 181, 0.35)"))
            case .sepia:
                Palette(foreground: "#3b2f1e", background: "#f8f1e3", marker: "rgba(59, 47, 30, 0.45)",
                        fontFamily: "-apple-system, 'Iowan Old Style', Georgia, serif",
                        highlights: .init(yellow: "rgba(240, 199, 56, 0.35)", green: "rgba(98, 165, 122, 0.35)",
                                          blue: "rgba(96, 138, 188, 0.35)", pink: "rgba(216, 128, 149, 0.35)",
                                          purple: "rgba(154, 111, 181, 0.35)"))
            case .night:
                Palette(foreground: "#d8d8dc", background: "#1c1c1e", marker: "rgba(216, 216, 220, 0.5)",
                        fontFamily: "-apple-system, 'Iowan Old Style', Georgia, serif",
                        highlights: .init(yellow: "rgba(240, 199, 56, 0.45)", green: "rgba(98, 165, 122, 0.45)",
                                          blue: "rgba(96, 138, 188, 0.45)", pink: "rgba(216, 128, 149, 0.45)",
                                          purple: "rgba(154, 111, 181, 0.45)"))
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
