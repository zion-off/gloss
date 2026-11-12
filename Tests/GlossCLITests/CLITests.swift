import Foundation
import Testing
@testable import GlossCLI
import GlossCore
import GlossTerminal
import GlossTestSupport

@Suite("cli: library")
struct CLILibraryTests {
    @Test("import adds files and folders, reports duplicates and fails on the rest")
    func importing() async throws {
        let cli = CLIHarness()
        try cli.file("books/a.fake", FakeFormat.file(title: "The Stranger"))
        try cli.file("books/nested/b.epub", EPUBBuilder().build())
        try cli.file("books/notes.txt", Data("nope".utf8))
        let first = await cli.run("import", "books")
        #expect(first.code == 0)
        #expect(first.out.contains("✔ added “The Stranger”"))
        #expect(first.out.contains("2 added, 0 already there, 0 failed"))

        let again = await cli.run("import", "books/a.fake", "missing.epub")
        #expect(again.code == 1)
        #expect(again.out.contains("↺ already have “The Stranger”"))
        #expect(again.err.contains("✘ couldn't find missing.epub"))
    }

    @Test("import --json reports each outcome")
    func importJSON() async throws {
        let cli = CLIHarness()
        try cli.file("a.fake", FakeFormat.file(title: "A"))
        try cli.file("junk.epub", Data("garbage".utf8))
        let result = await cli.run("import", "a.fake", "a.fake", "junk.epub", "--json")
        let json = try #require(try result.json() as? [String: Any])
        #expect((json["imported"] as? [[String: Any]])?.first?["title"] as? String == "A")
        #expect((json["duplicates"] as? [Any])?.count == 1)
        let failed = try #require(json["failed"] as? [[String: Any]])
        #expect(failed.count == 1)
        #expect(failed.first?["error"] as? String == "it looks damaged, so gloss couldn't read it")
        #expect(result.code == 1)
        #expect(result.err.isEmpty)
    }

    @Test("list sorts, filters by shelf and has a friendly empty state")
    func list() async throws {
        let cli = CLIHarness()
        #expect(await cli.run("list").out.contains("nothing glossed yet"))
        _ = try await cli.book("The Plague", author: "B")
        cli.library.clock.advance(by: 60)
        _ = try await cli.book("A Happy Death", author: "A")
        let byTitle = await cli.run("ls", "--sort", "title")
        let titles = byTitle.out.split(separator: "\n").dropFirst().map { $0.contains("Happy") ? "happy" : "plague" }
        #expect(titles == ["happy", "plague"])
        #expect(byTitle.out.hasPrefix("id"))
        let json = try #require(try await cli.run("list", "--sort", "author", "--json").json() as? [[String: Any]])
        #expect(json.map { $0["title"] as? String } == ["A Happy Death", "The Plague"])
        #expect(json.first?["url"] as? String == "gloss://book/\(json.first!["id"] as! String)")
        let badShelf = await cli.run("list", "--shelf", "comics")
        #expect(badShelf.code == 64)
        #expect(badShelf.err.contains("try one of: books"))
    }

    @Test("book show, edit and trash")
    func book() async throws {
        let cli = CLIHarness()
        let book = try await cli.book("Caligula")
        let shown = await cli.run("book", "show", "caligula")
        #expect(shown.out.contains("Caligula\nAlbert Camus"))
        #expect(shown.out.contains("gloss://book/\(book.id)"))
        // `book` alone shows.
        #expect(await cli.run("book", "Caligula").out.contains("linked passages"))

        #expect(await cli.run("book", "edit", "caligula").code == 64)
        let edited = await cli.run("book", "edit", "caligula", "--title", "Caligula (1944)", "--author", "Camus")
        #expect(edited.out.contains("✔ updated “Caligula (1944)”"))
        #expect(try await cli.services.library.document(book.id)?.author == "Camus")

        try cli.file("cover.png", EPUBBuilder.tinyPNG)
        try cli.file("cover.txt", Data("text".utf8))
        #expect(await cli.run("book", "edit", book.id.stringValue, "--cover", "cover.png").code == 0)
        #expect(try await cli.services.library.document(book.id)?.coverHash != nil)
        #expect(await cli.run("book", "edit", book.id.stringValue, "--cover", "cover.txt").err.contains("doesn't look like an image"))
        #expect(await cli.run("book", "edit", book.id.stringValue, "--reset-cover").code == 0)
        #expect(try await cli.services.library.document(book.id)?.coverHash == nil)

        let trashed = await cli.run("book", "trash", "Caligula (1944)")
        #expect(trashed.out.contains("moved “Caligula (1944)” and its notes to the trash"))
        let gone = await cli.run("book", "show", "Caligula (1944)")
        #expect(gone.code == 1)
        #expect(gone.err.contains("is in the trash"))
        #expect(gone.err.contains("gloss trash restore"))
    }

    @Test("highlights list in reading order and delete by short id")
    func highlights() async throws {
        let cli = CLIHarness()
        let book = try await cli.book("The Fall")
        let late = try await cli.services.highlights.add(cli.library.passage("late", at: "2", progression: 0.9), color: .pink, in: book.id)
        _ = try await cli.services.highlights.add(cli.library.passage("early words", at: "1", progression: 0.1), in: book.id)
        let listed = await cli.run("highlights", "The Fall")
        #expect(listed.out.range(of: "early words")!.lowerBound < listed.out.range(of: "late")!.lowerBound)
        let json = try #require(try await cli.run("highlights", "list", "The Fall", "--json").json() as? [[String: Any]])
        #expect(json.map { $0["color"] as? String } == ["yellow", "pink"])
        let deleted = await cli.run("highlights", "delete", String(late.id.stringValue.suffix(8)))
        #expect(deleted.out.contains("deleted the highlight “late”"))
        #expect(try await cli.services.highlights.highlights(in: book.id).count == 1)
        #expect(await cli.run("highlights", "delete", "zzzzzzzz").code == 1)
    }
}

@Suite("cli: pages")
struct CLIPageTests {
    @Test("write, append from stdin, add subpages and show the tree")
    func writing() async throws {
        let cli = CLIHarness()
        let book = try await cli.book("The Stranger")
        let write = await cli.run("page", "write", "the stranger", "# first\\nmeursault is calm")
        #expect(write.out.contains("✔ saved “The Stranger” (2 lines)"))
        cli.stdin = "the sun\n"
        let append = await cli.run("page", "write", "The Stranger", "--append")
        #expect(append.out.contains("added to"))
        let root = try #require(try await cli.services.pages.rootPage(of: book.id))
        #expect(root.body == "# first\nmeursault is calm\nthe sun\n")

        let added = await cli.run("page", "add", "The Stranger", "the trial", "--text", "the court")
        #expect(added.out.contains("✔ created “the trial” in “The Stranger”"))
        let tree = await cli.run("pages", "The Stranger")
        #expect(tree.out.contains("The Stranger"))
        #expect(tree.out.contains("└─ the trial"))
        #expect(tree.out.contains("1 line"))
        let json = try #require(try await cli.run("pages", "The Stranger", "--json").json() as? [String: Any])
        #expect((json["children"] as? [[String: Any]])?.first?["title"] as? String == "the trial")
    }

    @Test("writing needs text: an argument, a pipe or -")
    func writeNeedsText() async throws {
        let cli = CLIHarness()
        _ = try await cli.book("Book")
        cli.stdinIsTTY = true
        let result = await cli.run("page", "write", "Book")
        #expect(result.code == 64)
        #expect(result.err.contains("what should the page say?"))
        cli.stdin = "from stdin"
        #expect(await cli.run("page", "write", "Book", "-").code == 0)
    }

    @Test("read prints raw markdown when piped and renders on request")
    func reading() async throws {
        let cli = CLIHarness()
        let book = try await cli.book("The Myth")
        let target = try await cli.services.links.target(for: cli.library.passage("imagine", at: "c"), in: book.id)
        let root = try #require(try await cli.services.pages.rootPage(of: book.id))
        let body = "## one\n- [x] done\n> \(QuoteLine.make(quote: "imagine sisyphus", target: target.id).dropFirst(2))\nsee [web](https://x.y)"
        try await cli.services.pages.updateBody(root.id, to: body)
        _ = try await cli.services.pages.createSubpage(under: root.id, title: "unplaced")

        #expect(await cli.run("read", "The Myth").out == body + "\n")
        let rendered = await cli.run("read", "The Myth", "--rendered").out
        #expect(rendered.contains("The Myth\n\none"))
        #expect(rendered.contains("☑ done"))
        #expect(rendered.contains("│ imagine sisyphus ↗ chapter 1"))
        #expect(rendered.contains("web (https://x.y)"))
        #expect(rendered.contains("› unplaced"))
        let json = try #require(try await cli.run("read", "The Myth", "--json").json() as? [String: Any])
        #expect(json["body"] as? String == body)
        #expect(await cli.run("read", "x", "--raw", "--rendered").code == 64)
    }

    @Test("rendering on a colour terminal paints, and --no-color turns it off")
    func colour() async throws {
        let cli = CLIHarness()
        _ = try await cli.book("Colours")
        try await cli.services.pages.updateBody(try await cli.services.pages.rootPage(of: cli.services.library.entries()[0].id)!.id, to: "**bold**")
        cli.terminal = Terminal(colorEnabled: true, isTTY: true, width: 80)
        #expect(await cli.run("read", "Colours").out.contains("\u{1B}["))
        #expect(!(await cli.run("read", "Colours", "--no-color").out.contains("\u{1B}[1;")))
    }

    @Test("edit round-trips through the editor; no change saves nothing")
    func editing() async throws {
        let cli = CLIHarness()
        let book = try await cli.book("Edited")
        cli.edit = { $0 + "written in vim" }
        #expect(await cli.run("page", "edit", "Edited").out.contains("✔ saved “Edited”"))
        #expect(try await cli.services.pages.rootPage(of: book.id)?.body == "written in vim")
        cli.edit = { $0 }
        #expect(await cli.run("page", "edit", "Edited").out.contains("no changes"))
    }

    @Test("rename and trash pages; ambiguous names list the candidates")
    func renameAndTrash() async throws {
        let cli = CLIHarness()
        let a = try await cli.book("A")
        let b = try await cli.book("B")
        let rootA = try #require(try await cli.services.pages.rootPage(of: a.id))
        let rootB = try #require(try await cli.services.pages.rootPage(of: b.id))
        _ = try await cli.services.pages.createSubpage(under: rootA.id, title: "notes", appendBlockLine: true)
        let other = try await cli.services.pages.createSubpage(under: rootB.id, title: "notes")
        let ambiguous = await cli.run("page", "rename", "notes", "x")
        #expect(ambiguous.code == 1)
        #expect(ambiguous.err.contains("matches more than one page"))
        #expect(ambiguous.err.contains(String(other.id.stringValue.suffix(8))))

        let short = String(other.id.stringValue.suffix(8))
        #expect(await cli.run("page", "rename", short, "chapter", "one").out.contains("✔ renamed to “chapter one”"))
        let trashed = await cli.run("page", "trash", "chapter one")
        #expect(trashed.out.contains("moved “chapter one” to the trash"))
        #expect(try await cli.services.pages.page(other.id)?.trash != nil)
        #expect(await cli.run("page", "trash", "A").err.contains("can't be trashed on its own"))
    }

    @Test("references accept links, ids, short ids and titles")
    func references() async throws {
        let cli = CLIHarness()
        let book = try await cli.book("Noces")
        for ref in [GlossLink.document(book.id).string, book.id.stringValue, String(book.id.stringValue.suffix(8)),
                    String(book.id.stringValue.prefix(10)), "noces", "NOCÈS", "noc"] {
            #expect(await cli.run("book", "show", ref).code == 0, "\(ref)")
        }
        #expect(await cli.run("book", "show", "nope").err.contains("couldn't find a book called “nope”"))
        #expect(References.matchesFragment("abcdefgh", "abcd"))
        #expect(!References.matchesFragment("abcdefgh", "abc"))
        #expect(!References.matchesFragment("abcdefgh", "uuuu"))
    }
}

@Suite("cli: search, export, open")
struct CLISearchExportTests {
    @Test("search covers library and notes by default, and book text with --book")
    func search() async throws {
        let cli = CLIHarness()
        let book = try await cli.book("The Plague", chapters: ["rats appear in oran"])
        try await cli.services.pages.updateBody(try #require(try await cli.services.pages.rootPage(of: book.id)).id, to: "oran is a character")
        let all = await cli.run("search", "oran")
        #expect(all.out.contains("notes  1"))
        #expect(!all.out.contains("in the book"))
        let inBook = await cli.run("search", "oran", "--book", "plague")
        #expect(inBook.out.range(of: "notes")!.lowerBound < inBook.out.range(of: "in the book")!.lowerBound)
        #expect(inBook.out.contains("chapter 1"))
        let textOnly = try #require(try await cli.run("search", "rats", "--book", "plague", "--in", "text", "--json").json() as? [[String: Any]])
        #expect(textOnly.map { $0["group"] as? String } == ["book-text"])
        #expect((textOnly.first?["locator"] as? [String: Any])?["value"] as? String == "section-0")
        #expect(await cli.run("search", "rats", "--in", "text").code == 64)
        #expect(await cli.run("search", "xyzzy").out.contains("nothing matches “xyzzy”"))
    }

    @Test("export prints markdown, writes html to a folder, and exports single pages")
    func export() async throws {
        let cli = CLIHarness()
        let book = try await cli.book("Exile")
        let root = try #require(try await cli.services.pages.rootPage(of: book.id))
        try await cli.services.pages.updateBody(root.id, to: "root text")
        let sub = try await cli.services.pages.createSubpage(under: root.id, title: "sub", appendBlockLine: true)
        try await cli.services.pages.updateBody(sub.id, to: "sub text")
        let markdown = await cli.run("export", "Exile")
        #expect(markdown.out.hasPrefix("# Exile"))
        #expect(markdown.out.contains("## sub\n\nsub text"))
        // Just the main page: the link to a subpage outside the export becomes plain text.
        #expect(await cli.run("export", "Exile", "--page-only").out == "# Exile\n\nroot text\nsub\n")
        #expect(await cli.run("export", GlossLink.page(sub.id).string).out == "# sub\n\nsub text\n")

        try FileManager.default.createDirectory(at: cli.directory.appendingPathComponent("out"), withIntermediateDirectories: true)
        let html = await cli.run("export", "Exile", "--format", "html", "-o", "out")
        #expect(html.out.contains("exported to"))
        let written = cli.directory.appendingPathComponent("out/Exile.html")
        #expect(String(decoding: try Data(contentsOf: written), as: UTF8.self).contains("<title>Exile</title>"))
    }

    @Test("open hands gloss:// links to the system, or prints them where the app can't run")
    func open() async throws {
        let cli = CLIHarness()
        let book = try await cli.book("Betwixt")
        let fallback = await cli.run("open", "Betwixt")
        #expect(fallback.code == 0)
        #expect(fallback.out == GlossLink.document(book.id).string + "\n")
        #expect(fallback.err.contains("runs on macOS"))
        cli.openResult = .opened
        let root = try #require(try await cli.services.pages.rootPage(of: book.id))
        let opened = await cli.run("open", GlossLink.page(root.id).string)
        #expect(opened.out.contains("✔ opened gloss://page/\(root.id)"))
        #expect(cli.opened.last == GlossLink.page(root.id).url)
        #expect(await cli.run("open", "gloss://page/0000000000000000000000000z").err.contains("gone"))
    }
}

@Suite("cli: trash and maintenance")
struct CLITrashTests {
    @Test("list, restore and purge with confirmation")
    func trash() async throws {
        let cli = CLIHarness()
        let book = try await cli.book("Gone")
        #expect(await cli.run("trash").out.contains("the trash is empty"))
        _ = await cli.run("book", "trash", "Gone")
        let listed = await cli.run("trash", "list")
        #expect(listed.out.contains("book  Gone"))
        #expect(listed.out.contains("in 30 days"))
        #expect(await cli.run("trash", "restore", "gone").out.contains("✔ restored “Gone”"))
        #expect(try await cli.services.library.document(book.id)?.trash == nil)

        _ = await cli.run("book", "trash", "Gone")
        let refused = await cli.run("trash", "purge", "Gone")
        #expect(refused.code == 64)
        #expect(refused.err.contains("wants a --yes"))
        cli.stdinIsTTY = true
        cli.answers = ["n"]
        #expect(await cli.run("trash", "purge", "Gone").err.contains("kept it"))
        cli.answers = ["y"]
        #expect(await cli.run("trash", "purge", "Gone").out.contains("deleted “Gone” for good"))
        #expect(try await cli.services.library.document(book.id) == nil)
    }

    @Test("empty and keep")
    func emptyAndKeep() async throws {
        let cli = CLIHarness()
        _ = try await cli.book("One")
        _ = try await cli.book("Two")
        _ = await cli.run("book", "trash", "One")
        _ = await cli.run("book", "trash", "Two")
        #expect(await cli.run("trash", "empty", "--yes").out.contains("emptied the trash (2 things)"))
        #expect(await cli.run("trash", "empty").out.contains("already empty"))

        #expect(await cli.run("trash", "keep").out.contains("for 30 days"))
        #expect(await cli.run("trash", "keep", "1").out.contains("for 1 day"))
        #expect(await cli.run("trash", "keep", "forever").out.contains("forever"))
        #expect(try await cli.services.settings.value(TrashSettings.retentionDays) == nil)
        #expect(await cli.run("trash", "keep", "soon").code == 64)
    }

    @Test("backup, reindex and where")
    func maintenance() async throws {
        let cli = CLIHarness()
        _ = try await cli.book("Kept", chapters: ["a", "b"])
        try FileManager.default.createDirectory(at: cli.directory.appendingPathComponent("backups"), withIntermediateDirectories: true)
        let backup = await cli.run("backup", "backups")
        #expect(backup.out.contains("✔ backed up your library to"))
        let files = try FileManager.default.contentsOfDirectory(atPath: cli.directory.appendingPathComponent("backups").path)
        #expect(files.count == 1 && files[0].hasPrefix("gloss backup "))
        #expect(await cli.run("backup", "backups/" + files[0]).err.contains("never overwrites"))

        #expect(await cli.run("reindex").out.contains("1 book, 1 page, 2 sections of text"))
        #expect(await cli.run("where").out == "/memory/library.sqlite\n")
        #expect(try await cli.run("where", "--json").json() as? [String: String] == ["library": "/memory/library.sqlite"])
    }

    @Test("help and version work; unknown commands fail with usage")
    func help() async throws {
        let cli = CLIHarness()
        let help = await cli.run("--help")
        #expect(help.code == 0)
        #expect(help.out.contains("read, note and link books"))
        #expect(await cli.run("--version").out == "0.1.0\n")
        let unknown = await cli.run("teleport")
        #expect(unknown.code == 64)
        #expect(!unknown.err.isEmpty)
    }
}

@Suite("cli: formatting")
struct CLIFormatTests {
    @Test("relative dates, sizes and line counts read naturally")
    func formats() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Format.relative(now.addingTimeInterval(-10), now: now) == "just now")
        #expect(Format.relative(now.addingTimeInterval(-3600 * 5), now: now) == "5 hours ago")
        #expect(Format.relative(now.addingTimeInterval(-86_400), now: now) == "1 day ago")
        #expect(Format.future(now.addingTimeInterval(86_400 * 29.5), now: now) == "in 30 days")
        #expect(Format.bytes(512) == "512 bytes")
        #expect(Format.bytes(1536) == "1.5 KB")
        #expect(Format.bytes(50 * 1024 * 1024) == "50 MB")
        #expect(Format.lineCount("") == 0)
        #expect(Format.lineCount("a\nb\n") == 2)
        #expect(Format.lineCount("a\n\nb") == 3)
        #expect(Format.shortID("01m78xptr8fa4r6vwtr0f789s9") == "r0f789s9")
    }
}

@Suite("cli: review 2 regressions")
struct CLIReviewTwoTests {
    func ttyHarness() -> CLIHarness {
        let cli = CLIHarness()
        cli.terminal = Terminal(colorEnabled: true, isTTY: true, width: 80)
        return cli
    }

    @Test("--json on a terminal prints nothing but json", arguments: [
        ["import", "a.fake", "--json"], ["reindex", "--json"], ["backup", "copy.sqlite", "--json"], ["list", "--json"],
    ])
    func jsonOnATerminal(_ arguments: [String]) async throws {
        let cli = ttyHarness()
        try cli.file("a.fake", FakeFormat.file(title: "A"))
        if arguments[0] != "import" { _ = try await cli.book("Seed") }
        let result = await cli.run(arguments)
        #expect(result.code == 0, "\(result.err)")
        #expect(!result.out.contains("\u{1B}"), "\(arguments): escape codes on stdout")
        #expect(throws: Never.self) { _ = try result.json() }
    }

    @Test("status lines still show on a terminal without --json")
    func statusWithoutJSON() async throws {
        let cli = ttyHarness()
        _ = try await cli.book("Seed")
        #expect(await cli.run("reindex").out.contains("\r\u{1B}[2K"))
    }

    @Test("the delete-forever question goes to stderr, and --json never prompts")
    func confirmationStream() async throws {
        let cli = CLIHarness()
        _ = try await cli.book("Gone")
        _ = await cli.run("book", "trash", "Gone")
        cli.stdinIsTTY = true
        cli.answers = ["n"]
        let asked = await cli.run("trash", "purge", "Gone")
        #expect(asked.err.contains("delete “Gone” for good? [y/N]"))
        #expect(!asked.out.contains("[y/N]"))
        cli.answers = ["y"]
        let json = await cli.run("trash", "purge", "Gone", "--json")
        #expect(json.code == 64)
        #expect(json.out.isEmpty)
        #expect(json.err.contains("wants a --yes"))
        #expect(await cli.run("trash", "purge", "Gone", "--json", "--yes").code == 0)
    }
}
