import Foundation
import Testing
@testable import GlossCLI
import GlossCore
import GlossTerminal
import GlossTestSupport

@Suite("cli: part flags")
struct PartFlagsTests {
    @Test("the names formats supply become --part, after link only")
    func rewrite() {
        let names = ["section", "page"]
        #expect(PartFlags.rewrite(["link", "n", "--section", "5", "--offset", "1-2"], names: names)
            == ["link", "n", "--part", "section:5", "--offset", "1-2"])
        #expect(PartFlags.rewrite(["--json", "link", "--page=3", "n"], names: names) == ["--json", "link", "--part=page:3", "n"])
        #expect(PartFlags.rewrite(["read", "--page", "2"], names: names) == ["read", "--page", "2"])
        #expect(PartFlags.rewrite(["link", "n", "--", "--page"], names: names) == ["link", "n", "--", "--page"])
        #expect(PartFlags.Selection("section:7") == PartFlags.Selection("section:7"))
        #expect(PartFlags.Selection("7")?.noun == nil)
        #expect(PartFlags.Selection("page:x") == nil)
    }
}

@Suite("cli: link")
struct CLILinkTests {
    static let chapters = [
        "Call me Ishmael. The whale was white.",
        "The whale! said Ahab. Not the whale, said Starbuck.",
    ]

    func setUp(body: String = "a note about the whale and the whale") async throws -> (CLIHarness, Document) {
        let cli = CLIHarness()
        let book = try await cli.book("Moby", chapters: Self.chapters)
        #expect(await cli.run("page", "write", "Moby", body).code == 0)
        return (cli, book)
    }

    func body(_ cli: CLIHarness, _ book: Document) async throws -> String {
        try await cli.services.pages.rootPage(of: book.id)!.body
    }

    @Test("several matches: list each with the flags that pick it, exit 64, write nothing")
    func ambiguousBook() async throws {
        let (cli, book) = try await setUp()
        let result = await cli.run("link", "Moby", "--text", "a note", "--quote", "the whale", "-i")
        #expect(result.code == 64)
        #expect(result.err.contains("“the whale” appears 3 times in Moby"))
        #expect(result.err.contains("--nth 2  ·  --match fake:section-1@0-9"))
        #expect(result.err.contains("chapter 2"))
        #expect(result.err.contains("[The whale]! said Ahab."))
        #expect(try await body(cli, book) == "a note about the whale and the whale")

        let json = await cli.run("link", "Moby", "--text", "a note", "--quote", "the whale", "-i", "--json")
        #expect(json.code == 64)
        let object = try #require(try json.json() as? [String: Any])
        #expect(object["side"] as? String == "book")
        let candidates = try #require(object["candidates"] as? [[String: Any]])
        #expect(candidates.map { $0["ref"] as? String } == ["fake:section-0@17-26", "fake:section-1@0-9", "fake:section-1@26-35"])
        #expect(candidates.map { $0["number"] as? Int } == [1, 2, 3])
    }

    @Test("--nth, a --match ref from a listing, or section + offset link exactly; again is a no-op")
    func exactAndIdempotent() async throws {
        let (cli, book) = try await setUp()
        let listed = await cli.run("link", "Moby", "--quote", "the whale", "--list", "--json")
        let refs = try #require((try listed.json() as? [String: Any])?["book"] as? [[String: Any]]).compactMap { $0["ref"] as? String }
        #expect(refs == ["fake:section-1@26-35"])

        let first = await cli.run("link", "Moby", "--text", "a note", "--match", refs[0], "--quote", "the whale")
        #expect(first.code == 0, "\(first.err)")
        #expect(first.out.contains("✔ linked “a note”"))
        let linked = try await body(cli, book)
        #expect(linked.hasPrefix("[a note](gloss://passage/"))

        let again = await cli.run("link", "Moby", "--text", "a note", "--section", "2", "--offset", "26-35")
        #expect(again.code == 0)
        #expect(again.out.contains("already links"))
        #expect(try await body(cli, book) == linked)

        let byNth = await cli.run("link", "Moby", "--text", "the whale", "--text-nth", "2", "--quote", "the whale", "-i", "--nth", "1", "--json")
        #expect(byNth.code == 0)
        let object = try #require(try byNth.json() as? [String: Any])
        #expect(object["outcome"] as? String == "linked")
        #expect((object["passage"] as? [String: Any])?["ref"] as? String == "fake:section-0@17-26")
        #expect((object["words"] as? [String: Any])?["number"] as? Int == 2)
        #expect(try await body(cli, book).hasSuffix("and [the whale](\(object["url"] as! String))"))
    }

    @Test("checks: --quote must match the text at --match or --offset unless --force; --text likewise for --text-offset")
    func verification() async throws {
        let (cli, book) = try await setUp()
        let wrong = await cli.run("link", "Moby", "--text", "a note", "--match", "fake:section-1@26-35", "--quote", "the sea")
        #expect(wrong.code == 64)
        #expect(wrong.err.contains("says “the whale”, not “the sea”"))
        let words = await cli.run("link", "Moby", "--text-offset", "0-6", "--text", "a nose", "--match", "fake:section-1@26-35")
        #expect(words.code == 64)
        #expect(words.err.contains("the page says “a note” at 0-6"))
        #expect(try await body(cli, book) == "a note about the whale and the whale")
        let forced = await cli.run("link", "Moby", "--text-offset", "0-6", "--match", "fake:section-1@26-35", "--quote", "the sea", "--force")
        #expect(forced.code == 0)
        // the "[" shifted the words, but the same offsets still mean them: nothing changes
        let linked = try await body(cli, book)
        let rerun = await cli.run("link", "Moby", "--text-offset", "0-6", "--match", "fake:section-1@26-35", "--quote", "the sea", "--force")
        #expect(rerun.code == 0, "\(rerun.err)")
        #expect(rerun.out.contains("already links"))
        #expect(try await body(cli, book) == linked)
        let nowhere = await cli.run("link", "Moby", "--text", "a note", "--section", "9", "--offset", "0-3")
        #expect(nowhere.code == 64)
        let noun = await cli.run("link", "Moby", "--text", "a note", "--page", "2", "--quote", "whale")
        #expect(noun.err.contains("this book has sections, not pages"))
        // --part works whatever the format calls its parts
        let plain = await cli.run("link", "Moby", "--text", "a note", "--part", "2", "--offset", "26-35", "--dry-run")
        #expect(plain.code == 0, "\(plain.err)")
        #expect(await cli.run("link", "Moby", "--text", "a note", "--section", "2", "--page", "2", "--offset", "26-35").code == 64)
    }

    @Test("ambiguous words in the page are listed too; on a terminal gloss asks which")
    func ambiguousNotesAndPicker() async throws {
        let (cli, book) = try await setUp()
        let piped = await cli.run("link", "Moby", "--text", "the whale", "--match", "fake:section-1@26-35")
        #expect(piped.code == 64)
        #expect(piped.err.contains("“the whale” appears twice in Moby"))
        #expect(piped.err.contains("--text-nth 2  ·  --text-offset 27-36"))

        cli.stdinIsTTY = true
        cli.terminal = Terminal(colorEnabled: false, isTTY: true, width: 100)
        cli.answers = ["2"]
        let picked = await cli.run("link", "Moby", "--text", "the whale", "--match", "fake:section-1@26-35")
        #expect(picked.code == 0, "\(picked.err)")
        #expect(picked.err.contains("which one?"))
        #expect(try await body(cli, book).hasPrefix("a note about the whale and [the whale](gloss://passage/"))

        cli.answers = [""]
        let stopped = await cli.run("link", "Moby", "--quote", "the whale", "-i")
        #expect(stopped.code == 1)
        #expect(stopped.err.contains("nothing linked"))
    }

    @Test("without --text the passage becomes a quote line, once; --dry-run writes nothing; --to links across books")
    func quoteDryRunCrossBook() async throws {
        let (cli, book) = try await setUp(body: "")
        let other = try await cli.book("Other", chapters: ["nothing to see"])
        let dry = await cli.run("link", "Other", "--to", "Moby", "--quote", "Call me Ishmael", "--dry-run")
        #expect(dry.code == 0)
        #expect(dry.out.contains("would link"))
        #expect(try await cli.services.pages.rootPage(of: other.id)!.body == "")

        let quoted = await cli.run("link", "Other", "--to", "Moby", "--quote", "Call me Ishmael")
        #expect(quoted.code == 0)
        let body = try await cli.services.pages.rootPage(of: other.id)!.body
        #expect(body.hasPrefix("> Call me Ishmael [↗](gloss://passage/"))
        let again = await cli.run("link", "Other", "--to", "Moby", "--quote", "Call me Ishmael")
        #expect(again.out.contains("already quotes"))
        #expect(try await cli.services.pages.rootPage(of: other.id)!.body == body)
        // The marker belongs to the linked book, not the page's.
        #expect(try await cli.services.links.linkedPassages(in: book.id).count == 1)
    }

    @Test("usage mistakes are caught before anything is read")
    func usage() async throws {
        let (cli, _) = try await setUp()
        #expect(await cli.run("link", "Moby", "--text", "a note").code == 64)
        #expect(await cli.run("link", "Moby", "--from", "Call").code == 64)
        #expect(await cli.run("link", "Moby", "--offset", "1-3").code == 64)
        #expect(await cli.run("link", "Moby", "--match", "nonsense@1-2").code == 64)
        #expect(await cli.run("link", "Moby", "--quote", "x", "--nth", "0").code == 64)
        let ignored = await cli.run("link", "Moby", "--text", "a note", "--match", "fake:section-1@26-35", "--nth", "2", "--chapter", "1")
        #expect(ignored.code == 64)
        #expect(ignored.err.contains("--nth, --chapter would do nothing"))
        #expect(await cli.run("link", "Moby", "--text", "a note", "--section", "2", "--offset", "26-35", "--before", "x").code == 64)
        #expect(await cli.run("link", "Moby", "--text-offset", "0-6", "--text-nth", "1", "--quote", "whale").code == 64)
        let missing = await cli.run("link", "Moby", "--text", "nowhere", "--quote", "whale")
        #expect(missing.code == 1)
        #expect(missing.err.contains("couldn't find “nowhere” in Moby"))
    }
}
