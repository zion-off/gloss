import Foundation
import Testing
@testable import GlossCLI
import GlossCore
import GlossTestSupport

@Suite("cli: text and highlights by part")
struct CLIBookTextTests {
    static let chapters = [
        "Replication\nKeeping a copy of the same data on several machines.\nLeaders and Followers\nEach node that stores a copy is a replica.",
        "Partitioning\nSplitting the data. Each node that stores a copy is a replica.",
    ]

    func setUp() async throws -> (CLIHarness, Document) {
        let cli = CLIHarness()
        return (cli, try await cli.book("Data", chapters: Self.chapters))
    }

    @Test("without a part, text lists the parts with their numbers, titles, lengths and places")
    func listing() async throws {
        let (cli, _) = try await setUp()
        let listed = await cli.run("text", "Data")
        #expect(listed.code == 0, "\(listed.err)")
        #expect(listed.out.contains("chapter 2"))
        #expect(listed.out.contains("fake:section-1"))
        #expect(listed.out.contains("\(Self.chapters[0].utf16.count) chars"))
        let json = try #require(try await cli.run("text", "Data", "--json").json() as? [[String: Any]])
        #expect(json.map { $0["number"] as? Int } == [1, 2])
        #expect(json.map { $0["match"] as? String } == ["fake:section-0", "fake:section-1"])
    }

    @Test("a part prints its text, by number or title words; --from/--through cut a stretch")
    func printing() async throws {
        let (cli, _) = try await setUp()
        let whole = await cli.run("text", "Data", "--section", "2")
        #expect(whole.code == 0, "\(whole.err)")
        #expect(whole.out == Self.chapters[1] + "\n")
        #expect(whole.err.contains("--match fake:section-1@0-"))
        #expect(await cli.run("text", "Data", "--chapter", "chapter 2").out == whole.out)
        #expect(await cli.run("text", "Data", "--part", "2").out == whole.out)

        let cut = await cli.run("text", "Data", "--section", "1", "--from", "Leaders and Followers", "--through", "a replica.")
        #expect(cut.out == "Leaders and Followers\nEach node that stores a copy is a replica.\n")
        let tail = await cli.run("text", "Data", "--section", "1", "--from", "leaders  and followers", "-i")
        #expect(tail.out == cut.out)
        let head = await cli.run("text", "Data", "--section", "1", "--through", "machines.")
        #expect(head.out == "Replication\nKeeping a copy of the same data on several machines.\n")

        let json = try #require(try await cli.run("text", "Data", "--section", "1", "--from", "Leaders", "--through", "Followers", "--json").json() as? [String: Any])
        #expect(json["ref"] as? String == "fake:section-0@65-86")
        #expect(json["text"] as? String == "Leaders and Followers")
        #expect((json["part"] as? [String: Any])?["label"] as? String == "chapter 1")
    }

    @Test("several matches or several parts list and stop; nothing found says so")
    func neverGuesses() async throws {
        let (cli, _) = try await setUp()
        let twice = await cli.run("text", "Data", "--from", "Each node")
        #expect(twice.code == 64)
        #expect(twice.err.contains("“Each node” appears twice in Data"))
        #expect(twice.err.contains("--nth 2  ·  --section 2"))
        let picked = await cli.run("text", "Data", "--from", "Each node", "--nth", "2")
        #expect(picked.out == "Each node that stores a copy is a replica.\n")
        let parts = await cli.run("text", "Data", "--chapter", "chapter")
        #expect(parts.code == 64)
        #expect(parts.err.contains("--section 2  chapter 2"))
        #expect(await cli.run("text", "Data", "--section", "9").code == 1)
        #expect(await cli.run("text", "Data", "--section", "1", "--from", "nowhere").code == 1)
        #expect(await cli.run("text", "Data", "--page", "1").err.contains("this book has sections, not pages"))
        #expect(await cli.run("text", "Data", "--nth", "2").code == 64)
    }

    @Test("highlights show their part, a --match ref and heading guesses, and filter to one part")
    func highlights() async throws {
        let (cli, book) = try await setUp()
        func add(_ quote: String, section: Int?) async throws {
            let locator = section.map { Locator(scheme: FakeFormat.scheme, value: "section-\($0)") } ?? Locator(scheme: LocatorScheme("x"), value: "")
            _ = try await cli.services.highlights.add(Passage(locator: locator, quote: quote, progression: Double(section ?? 0)), in: book.id)
        }
        try await add("Leaders and Followers", section: 0)
        try await add("Splitting the data.", section: 1)
        try await add("a replica.", section: nil)  // in both parts, and the locator doesn't say

        let all = await cli.run("highlights", "Data")
        #expect(all.code == 0, "\(all.err)")
        #expect(all.out.contains("“Leaders and Followers” heading?"))
        #expect(all.out.contains("--match fake:section-0@65-86"))
        #expect(all.out.contains("“a replica.”"))

        let one = await cli.run("highlights", "Data", "--section", "2")
        #expect(one.code == 0, "\(one.err)")
        #expect(one.out.contains("Splitting the data."))
        #expect(!one.out.contains("Leaders"))
        #expect(one.err.contains("1 highlight couldn't be placed in a section"))

        let json = try #require(try await cli.run("highlights", "Data", "--chapter", "1", "--json").json() as? [[String: Any]])
        #expect(json.count == 1)
        #expect(json[0]["part"] as? Int == 1)
        #expect(json[0]["heading"] as? Bool == true)
        #expect(json[0]["ref"] as? String == "fake:section-0@65-86")
        // The ref links exactly the highlighted words.
        #expect(await cli.run("page", "write", "Data", "see leaders").code == 0)
        let linked = await cli.run("link", "Data", "--text", "leaders", "--match", "fake:section-0@65-86")
        #expect(linked.code == 0, "\(linked.err)")
    }
}
