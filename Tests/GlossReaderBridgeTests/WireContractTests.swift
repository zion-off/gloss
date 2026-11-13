import Foundation
import Testing
@testable import GlossReaderBridge

/// The cross-language contract: what Swift actually puts on the wire is committed under
/// `Tests/Fixtures/bridge/swift-encoded/`, and `web/test/protocol.test.ts` runs the real
/// validator over every file there. Review 1 found nil fields Swift left out but JS required;
/// fixtures written by hand could never show that.
///
/// After changing an encoding, regenerate with `GLOSS_UPDATE_FIXTURES=1 swift test --filter WireContract`.
@Suite("bridge wire contract")
struct WireContractTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/bridge/swift-encoded/commands")

    static let appearance = AppearanceStyler().appearance(for: ReaderSettings())

    /// Every command type, plus each nullable field in its empty form.
    static let commands: [(name: String, command: ReaderCommand)] = [
        ("open", .open(ReaderOpenPayload(openID: 1, url: "gloss-reader://app/book/01m78xptr8fa4r6vwtr0f789s9",
                                         position: "epubcfi(/6/8!/4/2/1:0)", appearance: appearance))),
        ("open-without-position", .open(ReaderOpenPayload(openID: 2, url: "gloss-reader://app/book/01m78xptr8fa4r6vwtr0f789s9",
                                                          position: nil, appearance: appearance))),
        ("close", .close),
        ("goTo-cfi", .goTo(ReaderGoToPayload(target: .cfi("epubcfi(/6/10!/4/2/2/1:12)"), flash: true))),
        ("goTo-href", .goTo(ReaderGoToPayload(target: .href("text/ch001.xhtml")))),
        ("goTo-fraction", .goTo(ReaderGoToPayload(target: .fraction(0.5)))),
        ("goTo-quote", .goTo(ReaderGoToPayload(target: .quote(ReaderQuoteTarget(section: 4, text: "the whale", prefix: "Not",
                                                                                suffix: ", said", occurrence: 1)), flash: true))),
        ("turnPage", .turnPage(ReaderTurnPagePayload(direction: .forward))),
        ("setAppearance", .setAppearance(ReaderSetAppearancePayload(appearance: appearance))),
        ("setAnnotations", .setAnnotations(ReaderSetAnnotationsPayload(
            highlights: [ReaderHighlightAnnotation(id: "01m78xptr8fa4r6vwtr0f789s9", cfi: "epubcfi(/6/8!/4/2/1:3,/4/2/1:9)", color: .blue)],
            markers: [ReaderMarkerAnnotation(id: "01m78xptr8fa4r6vwtr0f789t0", cfi: "epubcfi(/6/8!/4/2/1:3,/4/2/1:9)")]))),
        ("setAnnotations-empty", .setAnnotations(ReaderSetAnnotationsPayload())),
        ("setAnnotations-quote", .setAnnotations(ReaderSetAnnotationsPayload(markers: [
            ReaderMarkerAnnotation(id: "01m78xptr8fa4r6vwtr0f789t0",
                                   quote: ReaderQuoteTarget(section: 4, text: "the whale", prefix: "Not", suffix: ", said", occurrence: 1)),
        ]))),
        ("clearSelection", .clearSelection),
        ("search", .search(ReaderSearchPayload(query: "white whale"))),
        ("clearSearch", .clearSearch),
        ("revealSearchHit-cfi", .revealSearchHit(ReaderRevealSearchHitPayload(cfi: "epubcfi(/6/12!/4/2/1:10)", text: "whale"))),
        ("revealSearchHit-section", .revealSearchHit(ReaderRevealSearchHitPayload(section: 3, text: "whale"))),
        ("revealSearchHit-text-only", .revealSearchHit(ReaderRevealSearchHitPayload(text: "whale"))),
    ]

    static func encode(_ command: ReaderCommand) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(command), as: UTF8.self) + "\n"
    }

    @Test("the committed swift encodings match what swift encodes")
    func committedEncodings() throws {
        let update = ProcessInfo.processInfo.environment["GLOSS_UPDATE_FIXTURES"] == "1"
        if update { try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true) }
        for (name, command) in Self.commands {
            let url = Self.directory.appendingPathComponent("\(name).json")
            let encoded = try Self.encode(command)
            if update { try Data(encoded.utf8).write(to: url) }
            let committed = try? String(contentsOf: url, encoding: .utf8)
            #expect(committed == encoded, "\(name).json is stale; regenerate with GLOSS_UPDATE_FIXTURES=1")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path).filter { $0.hasSuffix(".json") }
        #expect(Set(files) == Set(Self.commands.map { "\($0.name).json" }), "remove stale files from swift-encoded/")
    }

    @Test("every command type is covered")
    func coverage() throws {
        let types = try Set(Self.commands.map { command -> String in
            let object = try JSONSerialization.jsonObject(with: Data(try Self.encode(command.command).utf8)) as? [String: Any]
            return object?["type"] as? String ?? ""
        })
        #expect(types == Set(ReaderCommand.typeNames))
    }

    @Test("empty nullable fields go on the wire as null")
    func nullsAreExplicit() throws {
        let open = try Self.encode(.open(ReaderOpenPayload(openID: 1, url: "u", position: nil, appearance: Self.appearance)))
        #expect(open.contains("\"position\" : null"))
        let reveal = try Self.encode(.revealSearchHit(ReaderRevealSearchHitPayload(text: "t")))
        #expect(reveal.contains("\"cfi\" : null"))
        #expect(reveal.contains("\"section\" : null"))
        // And they still decode back.
        #expect(try JSONDecoder().decode(ReaderCommand.self, from: Data(open.utf8))
                == .open(ReaderOpenPayload(openID: 1, url: "u", position: nil, appearance: Self.appearance)))
    }
}
