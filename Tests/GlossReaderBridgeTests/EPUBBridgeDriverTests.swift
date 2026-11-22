import Foundation
import Testing
@testable import GlossReaderBridge
import GlossCore
import GlossEPUB

@MainActor
struct EPUBBridgeDriverTests {
    let appearance = AppearanceStyler().appearance(for: ReaderSettings())
    let document = Document(id: DocumentID(GlossID(high: 0x7000, low: 5)), kind: .epub, title: "t", author: "a",
                            contentHash: .of(Data("x".utf8)), fileSize: 1, addedAt: Date(), updatedAt: Date())

    func driver() -> (EPUBBridgeDriver, () -> [ReaderCommand]) {
        var sent: [ReaderCommand] = []
        let driver = EPUBBridgeDriver(appearance: appearance) { sent.append($0) }
        return (driver, { sent })
    }

    @Test("commands map onto the bridge protocol")
    func commands() async throws {
        let (driver, sent) = driver()
        let cfi = Locator(scheme: EPUBLocators.cfiScheme, value: "epubcfi(/6/8!/4/2/1:3)")
        try await driver.open(document, at: cfi, openID: 7)
        try await driver.go(to: cfi)
        try await driver.go(to: Locator(scheme: EPUBLocators.hrefScheme, value: "ch1.xhtml"))
        try await driver.turnPage(forward: false)
        try await driver.clearSelection()
        try await driver.reveal(searchHit: Locator(scheme: EPUBLocators.sectionScheme, value: "3"), text: "whale", anchor: nil)
        try await driver.reveal(searchHit: Locator(scheme: EPUBLocators.sectionScheme, value: "3"), text: "whale",
                                anchor: QuoteAnchor(text: "whale", prefix: "the white", suffix: ", said", occurrence: 4))
        try await driver.close()
        #expect(sent() == [
            .open(ReaderOpenPayload(openID: 7, url: "gloss-reader://app/book/\(document.id)", position: cfi.value, appearance: appearance)),
            .goTo(ReaderGoToPayload(target: .cfi(cfi.value))),
            .goTo(ReaderGoToPayload(target: .href("ch1.xhtml"))),
            .turnPage(ReaderTurnPagePayload(direction: .backward)),
            .clearSelection,
            .revealSearchHit(ReaderRevealSearchHitPayload(cfi: nil, section: 3, text: "whale")),
            .revealSearchHit(ReaderRevealSearchHitPayload(cfi: nil, section: 3, text: "whale", quote: ReaderQuoteTarget(
                section: 3, text: "whale", prefix: "the white", suffix: ", said", occurrence: 4))),
            .close,
        ])
    }

    @Test("positions from other engines open at the start; foreign locators are refused")
    func foreignLocators() async throws {
        let (driver, sent) = driver()
        try await driver.open(document, at: Locator(scheme: LocatorScheme("pdf"), value: "{}"), openID: 1)
        guard case .open(let payload) = sent().first else { Issue.record(); return }
        #expect(payload.position == nil)
        await #expect(throws: ReaderDrivingError.unsupportedLocator(EPUBLocators.sectionScheme)) {
            try await driver.go(to: Locator(scheme: EPUBLocators.sectionScheme, value: "1"))
        }
    }

    @Test("annotations keep only CFI locators and become highlight and marker payloads")
    func annotations() async throws {
        let (driver, sent) = driver()
        let cfi = Locator(scheme: EPUBLocators.cfiScheme, value: "epubcfi(/6/2!/4/1:0)")
        let annotations = ReaderAnnotations(
            highlights: [.init(id: HighlightID(GlossID(high: 1, low: 1)), locator: cfi, color: .pink),
                         .init(id: HighlightID(GlossID(high: 1, low: 2)), locator: Locator(scheme: LocatorScheme("pdf"), value: "x"), color: .blue)],
            markers: [.init(id: LinkTargetID(GlossID(high: 1, low: 3)), locator: cfi)])
        try await driver.show(annotations)
        guard case .setAnnotations(let payload) = sent().first else { Issue.record(); return }
        #expect(payload.highlights.map(\.color) == [.pink])
        #expect(payload.markers.map(\.cfi) == [cfi.value])
    }

    @Test("quote locators (gloss link) go to and mark their words through the glue; broken ones are refused or skipped")
    func quoteLocators() async throws {
        let (driver, sent) = driver()
        let anchor = QuoteAnchor(text: "the whale", prefix: "Not", suffix: ", said", occurrence: 1)
        let quote = EPUBQuoteLocator(section: 4, quote: anchor).locator
        let target = ReaderQuoteTarget(section: 4, text: "the whale", prefix: "Not", suffix: ", said", occurrence: 1)
        try await driver.go(to: quote)
        try await driver.show(ReaderAnnotations(markers: [
            .init(id: LinkTargetID(GlossID(high: 1, low: 3)), locator: quote),
            .init(id: LinkTargetID(GlossID(high: 1, low: 4)), locator: Locator(scheme: EPUBLocators.quoteScheme, value: "{broken")),
        ]))
        #expect(sent() == [
            .goTo(ReaderGoToPayload(target: .quote(target))),
            .setAnnotations(ReaderSetAnnotationsPayload(markers: [
                ReaderMarkerAnnotation(id: LinkTargetID(GlossID(high: 1, low: 3)).stringValue, quote: target),
            ])),
        ])
        await #expect(throws: ReaderDrivingError.unsupportedLocator(EPUBLocators.quoteScheme)) {
            try await driver.go(to: Locator(scheme: EPUBLocators.quoteScheme, value: "{broken"))
        }
        // A marker carries exactly one of cfi or quote.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ReaderMarkerAnnotation.self, from: Data(#"{"id":"x"}"#.utf8))
        }
    }

    @Test("appearance changes are remembered for the next open")
    func appearanceChange() async throws {
        let (driver, sent) = driver()
        var night = ReaderSettings()
        night.theme = .night
        let dark = AppearanceStyler().appearance(for: night)
        try await driver.apply(dark)
        try await driver.open(document, at: nil, openID: 2)
        guard case .open(let payload) = sent().last else { Issue.record(); return }
        #expect(payload.appearance == dark)
    }

    @Test("every event fixture translates")
    func translateFixtures() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/bridge/events")
        var translated: [String: ReaderEngineEvent?] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            translated[url.deletingPathExtension().lastPathComponent] = EPUBBridgeDriver.translate(try ReaderEvent.decode(fromJSON: Data(contentsOf: url)))
        }
        guard case .relocated(let location)?? = translated["relocated"] else { Issue.record(); return }
        #expect(location.locator == Locator(scheme: EPUBLocators.cfiScheme, value: "epubcfi(/6/8!/4/2/1:23)"))
        #expect(location.progressText == "7 pages left in Chapter 1. Loomings")
        guard case .opened(let toc, let openID)?? = translated["opened"] else { Issue.record(); return }
        #expect(openID == 3)
        #expect(toc.first?.children.first?.target == Locator(scheme: EPUBLocators.hrefScheme, value: "text/ch001.xhtml"))
        guard case .annotationActivated(let highlights, let markers, _)?? = translated["annotationActivated"] else { Issue.record(); return }
        // Fixture ids are 20 characters (not gloss ids), so they drop out rather than crash.
        #expect(highlights.isEmpty && markers.isEmpty)
        guard case .selectionChanged(let passage, _)?? = translated["selectionChanged"] else { Issue.record(); return }
        #expect(passage.label == "Chapter 1. Loomings")
        #expect(translated["error"] == .some(.failed("open: fetch gloss-reader://books/missing.blob failed: 404 Not Found")))

        // An error naming an open is that open's failure, not a generic one, and the id survives
        // the Swift codec.
        let openFailure = ReaderEvent.error(ReaderErrorPayload(message: "fetch failed", context: "open", openID: 3))
        let decoded = try JSONDecoder().decode(ReaderEvent.self, from: JSONEncoder().encode(openFailure))
        #expect(EPUBBridgeDriver.translate(decoded) == .openFailed("fetch failed", openID: 3))
        #expect(translated["linkActivated"] == .some(.externalLink(URL(string: "https://www.gutenberg.org/ebooks/2701")!)))
    }

    @Test("script messages arrive as JSON text; anything else is malformed")
    func messageBodies() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/bridge/events/relocated.json")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        guard case .relocated(let location)? = try EPUBBridgeDriver.engineEvent(fromMessageBody: text) else { Issue.record(); return }
        #expect(location.progression > 0)
        #expect(try EPUBBridgeDriver.engineEvent(fromMessageBody: #"{"v":1,"type":"ready","payload":{}}"#) == .ready)

        // An object (what WebKit would hand over for a posted JS object) is refused, not guessed at.
        #expect(throws: ReaderBridgeError.self) {
            try EPUBBridgeDriver.engineEvent(fromMessageBody: ["v": 1, "type": "ready", "payload": [String: Int]()] as [String: Any])
        }
        #expect(throws: (any Error).self) { try EPUBBridgeDriver.engineEvent(fromMessageBody: "not json") }
        #expect(throws: (any Error).self) { try EPUBBridgeDriver.engineEvent(fromMessageBody: #"{"v":2,"type":"ready","payload":{}}"#) }
    }
}
