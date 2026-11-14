import Foundation
import Testing
@testable import GlossReaderBridge
import GlossCore
import GlossTestSupport
import GlossEPUB

/// The fixtures are the contract: the same files the Node suite validates (web/test/protocol.test.ts).
@Suite("bridge fixtures")
struct BridgeFixtureTests {
    static let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/bridge")

    static func fixtureURLs(_ subdirectory: String) throws -> [URL] {
        let directory = fixtureRoot.appendingPathComponent(subdirectory)
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return contents.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test("every command fixture decodes, round-trips and carries the protocol version")
    func commands() throws {
        let urls = try Self.fixtureURLs("commands")
        #expect(Set(urls.map(\.lastPathComponent)) == Set(ReaderCommand.typeNames.map { "\($0).json" }))
        for url in urls {
            let data = try Data(contentsOf: url)
            let command = try JSONDecoder().decode(ReaderCommand.self, from: data)
            let reencoded = try JSONEncoder().encode(command)
            let roundTrip = try JSONDecoder().decode(ReaderCommand.self, from: reencoded)
            #expect(roundTrip == command, "\(url.lastPathComponent)")
            let object = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
            #expect(object["v"] as? Int == ReaderBridge.protocolVersion)
            #expect(object["type"] != nil)
            _ = try command.encodedString()
        }
    }

    @Test("every event fixture decodes, round-trips and carries the protocol version")
    func events() throws {
        let urls = try Self.fixtureURLs("events")
        #expect(Set(urls.map(\.lastPathComponent)) == Set(ReaderEvent.typeNames.map { "\($0).json" }))
        for url in urls {
            let data = try Data(contentsOf: url)
            let event = try ReaderEvent.decode(fromJSON: data)
            let reencoded = try JSONEncoder().encode(event)
            #expect(try JSONDecoder().decode(ReaderEvent.self, from: reencoded) == event)
            let object = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
            #expect(object["v"] as? Int == ReaderBridge.protocolVersion)
        }
    }

    @Test("specific payloads decode with their exact shapes")
    func shapes() throws {
        let relocated = try JSONDecoder().decode(ReaderEvent.self, from: try Data(contentsOf: Self.fixtureURLs("events")
            .first { $0.lastPathComponent == "relocated.json" }!))
        guard case .relocated(let payload) = relocated else { Issue.record(); return }
        #expect(payload.cfi == "epubcfi(/6/8!/4/2/1:23)")
        #expect(payload.section == ReaderSectionProgress(index: 3, count: 14))
        #expect(payload.pagesLeftInSection == 7)
        #expect(payload.atEnd == false)

        let opened = try JSONDecoder().decode(ReaderEvent.self, from: try Data(contentsOf: Self.fixtureURLs("events")
            .first { $0.lastPathComponent == "opened.json" }!))
        guard case .opened(let openPayload) = opened else { Issue.record(); return }
        #expect(openPayload.toc.first?.children.count == 2)
        #expect(openPayload.toc.first?.walk().count == 3)
        #expect(openPayload.direction == .ltr)
    }

    @Test("bad envelopes are rejected with the right errors")
    func rejects() throws {
        func decodeCommand(_ json: String) throws -> ReaderCommand {
            try JSONDecoder().decode(ReaderCommand.self, from: Data(json.utf8))
        }
        #expect(throws: ReaderBridgeError.unsupportedVersion(2)) {
            try decodeCommand(#"{"v": 2, "type": "search", "payload": {"query": "x"}}"#)
        }
        #expect(throws: ReaderBridgeError.unknownType("teleport")) {
            try decodeCommand(#"{"v": 1, "type": "teleport", "payload": {}}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeCommand(#"{"v": 1, "type": "search", "payload": {}}"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeCommand(#"{"v": 1, "type": "goTo", "payload": {"target": {}}}"#)
        }
        #expect(throws: DecodingError.self) {
            try ReaderEvent.decode(fromJSON: Data(#"{"v": 1, "type": "relocated", "payload": {"cfi": "x"}}"#.utf8))
        }
        #expect(throws: ReaderBridgeError.unknownType("relocated")) {
            try JSONDecoder().decode(ReaderCommand.self, from: Data(#"{"v": 1, "type": "relocated", "payload": {}}"#.utf8))
        }
    }

    @Test("reader targets encode to their single-key form")
    func targets() throws {
        func roundTrip(_ target: ReaderTarget) throws -> ReaderTarget {
            try JSONDecoder().decode(ReaderTarget.self, from: JSONEncoder().encode(target))
        }
        #expect(try roundTrip(.cfi("epubcfi(/6/8)")) == .cfi("epubcfi(/6/8)"))
        #expect(try roundTrip(.href("text/ch1.xhtml")) == .href("text/ch1.xhtml"))
        #expect(try roundTrip(.fraction(0.5)) == .fraction(0.5))
        #expect(ReaderTarget.cfi("x").locatorValue == "x")
        #expect(ReaderTarget.href("y").locatorValue == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ReaderTarget.self, from: Data("{}".utf8))
        }
    }
}

@Suite("appearance")
struct AppearanceTests {
    let styler = AppearanceStyler()

    @Test("the styler produces the css, layout and colours for each theme")
    func styling() {
        var settings = ReaderSettings()
        settings.fontSize = 19
        settings.lineHeight = 1.7
        let appearance = styler.appearance(for: settings)
        #expect(appearance.flow == .paginated)
        #expect(appearance.layout == ReaderLayout(margin: 48, gap: 0.06, maxInlineSize: 720, maxColumnCount: 2))
        #expect(appearance.colors.background == "#f8f1e3")
        #expect(appearance.css.contains("font-size: 19px"))
        #expect(appearance.css.contains("line-height: 1.7"))
        #expect(appearance.css.contains("color-scheme: light"))
        #expect(!appearance.css.contains("color-scheme: dark"))
        // One page colour: the theme's on html wins over the book's, body backgrounds go.
        #expect(appearance.css.contains("background: #f8f1e3 !important"))
        #expect(appearance.css.contains("background: transparent !important"))

        var night = settings
        night.theme = .night
        night.flow = .scrolled
        night.margin = 32
        let dark = styler.appearance(for: night)
        #expect(dark.flow == .scrolled)
        #expect(dark.layout.margin == 32)
        #expect(dark.css.contains("color-scheme: dark"))
        #expect(dark.css.contains("body * { color: inherit !important"))
        #expect(!appearance.css.contains("body *"))
        #expect(dark.colors.background == "#1c1c1e")
        #expect(dark.colors.marker.contains("0.5"))
    }

    @Test("every theme has its own valid shade of each highlight colour")
    func themedHighlights() {
        let themes = ReaderSettings.Theme.allCases
        for theme in themes {
            let shades = AppearanceStyler.pageHighlights(for: theme)
            for name in [ReaderColorName.yellow, .green, .blue, .pink, .purple] { #expect(CSSColor(rgba: shades[name]) != nil, "\(theme) \(name)") }
            var settings = ReaderSettings()
            settings.theme = theme
            #expect(styler.appearance(for: settings).colors.highlights == shades)
        }
        #expect(Set(themes.map { AppearanceStyler.pageHighlights(for: $0) }).count == themes.count)
    }

    @Test("highlight colour names map both ways with HighlightColor")
    func colors() {
        #expect(ReaderColorName(.yellow) == .yellow)
        #expect(ReaderColorName(.purple).highlightColor == .purple)
        #expect(ReaderColorName(rawValue: "yellow")!.highlightColor == .yellow)
    }

    @Test("reader settings persist through the settings store")
    func persistence() async throws {
        let lib = TestLibrary()
        let store = ReaderSettingsStore(settings: lib.services.settings)
        var settings = try await store.load()
        #expect(settings == ReaderSettings())
        settings.theme = .night
        settings.fontSize = 21
        try await store.save(settings)
        #expect(try await store.load() == settings)
    }
}

@Suite("reader progress and event mapping")
struct ReaderProgressTests {
    func relocated(pagesLeft: Int? = nil, tocLabel: String? = nil, fraction: Double = 0.28,
                   atStart: Bool = false, atEnd: Bool = false) -> ReaderRelocatedPayload {
        ReaderRelocatedPayload(cfi: "epubcfi(/6/8!/4/2/1:23)", fraction: fraction, section: ReaderSectionProgress(index: 3, count: 14),
                               tocLabel: tocLabel, pageLabel: nil, pagesLeftInSection: pagesLeft, atStart: atStart, atEnd: atEnd)
    }

    @Test("progress text reads like Apple Books")
    func text() {
        #expect(ReaderProgressText.describe(relocated(pagesLeft: 1, tocLabel: "Loomings")) == "1 page left in Loomings")
        #expect(ReaderProgressText.describe(relocated(pagesLeft: 7, tocLabel: "Loomings")) == "7 pages left in Loomings")
        #expect(ReaderProgressText.describe(relocated(pagesLeft: 0, tocLabel: "Loomings")) == "28% in")
        #expect(ReaderProgressText.describe(relocated(atEnd: true)) == "the end")
        #expect(ReaderProgressText.describe(relocated(fraction: 0, atStart: true)) == "the start")
        #expect(ReaderProgressText.describe(relocated(pagesLeft: 3, tocLabel: " ")) == "3 pages left in section 4")
    }

    @Test("events map into core passages and positions")
    func mapping() {
        let selection = ReaderSelectionChangedPayload(cfi: "epubcfi(/6/8!/4/2/1:23,/4/2/1:57)",
                                                      text: "Call me Ishmael.", label: "Chapter 1. Loomings",
                                                      fraction: 0.281, rect: ReaderRect(x: 96, y: 208, width: 412, height: 22))
        let passage = ReaderEventMapping.passage(from: selection)
        #expect(passage.locator == Locator(scheme: EPUBLocators.cfiScheme, value: "epubcfi(/6/8!/4/2/1:23,/4/2/1:57)"))
        #expect(passage.quote == "Call me Ishmael.")
        #expect(passage.label == "Chapter 1. Loomings")
        #expect(passage.progression == 0.281)

        let document = DocumentID(GlossID(high: 1, low: 1))
        let position = ReaderEventMapping.readingPosition(from: relocated(pagesLeft: 7, tocLabel: "Loomings"),
                                                         of: document, updatedAt: .testEpoch)
        #expect(position.locator.value == "epubcfi(/6/8!/4/2/1:23)")
        #expect(position.label == "Loomings")
        #expect(ReaderEventMapping.progressLabel(of: relocated(tocLabel: nil)) == "section 4")
        #expect(ReaderEventMapping.progressLabel(of: relocated(tocLabel: "Loomings")) == "Loomings")
    }
}

@Suite("reader rects")
struct ReaderRectTests {
    @Test("bottom-left measurements flip into the top-left contract")
    func fromBottomLeft() {
        // 20 tall, ending 30 from the bottom of a 500-tall view: its top is 450 from the top.
        #expect(ReaderRect.fromBottomLeft(x: 4, y: 10, width: 8, height: 20, containerHeight: 500)
                == ReaderRect(x: 4, y: 470, width: 8, height: 20))
        #expect(ReaderRect.fromBottomLeft(x: 0, y: 480, width: 1, height: 20, containerHeight: 500).y == 0)
    }
}
