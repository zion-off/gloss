import Foundation
import Testing
@testable import GlossCore
import GlossTestSupport

@Suite("import")
struct ImportTests {
    @Test("importing creates a document, an empty root page titled after the book, and indexes")
    func importsBook() async throws {
        let lib = TestLibrary()
        let progress = Locked<[ImportProgress]>([])
        let outcome = try await lib.services.imports.importData(FakeFormat.file(title: "The White Album", author: "Joan Didion"),
                                                                filename: "album.fake") { event in progress.withLock { $0.append(event) } }
        guard case .imported(let document) = outcome else { Issue.record("expected an import"); return }
        #expect(document.title == "The White Album")
        #expect(document.author == "Joan Didion")
        #expect(document.kind == FakeFormat.kind)
        let root = try #require(try await lib.services.pages.rootPage(of: document.id))
        #expect(root.title == "The White Album")
        #expect(root.body.isEmpty)
        #expect(progress.current == [.storing, .indexing, .done])
        #expect(try await lib.blobs.contains(document.contentHash))
        let hits = try await lib.services.search.search("didion", in: .library)
        #expect(hits.first?.hits.first?.destination == .document(document.id))
    }

    @Test("duplicates are detected by content, whatever the file is called")
    func duplicates() async throws {
        let lib = TestLibrary()
        let data = FakeFormat.file()
        let first = try await lib.services.imports.importData(data, filename: "a.fake")
        let second = try await lib.services.imports.importData(data, filename: "copy of a.fake")
        #expect(second == .duplicate(first.document))
        #expect(try await lib.services.library.entries().count == 1)
    }

    @Test("unknown formats are refused with friendly copy")
    func unsupported() async throws {
        let lib = TestLibrary()
        await #expect(throws: GlossError.unsupportedFormat(".mobi")) {
            try await lib.services.imports.importData(Data("nope".utf8), filename: "book.mobi")
        }
    }

    @Test("a file its format can't read is refused, not stored as a broken book")
    func damaged() async throws {
        struct ParserFailure: Error {}
        struct Strict: DocumentFormat {
            var kind: DocumentKind { DocumentKind("strict") }
            var badge: String { "strict" }
            var shelf: LibraryShelf { .books }
            var fileExtensions: [String] { ["strict"] }
            func sniff(_ prefix: Data) -> Bool { false }
            func readMetadata(from data: Data) throws -> ImportedMetadata {
                switch String(decoding: data, as: UTF8.self) {
                case "locked": throw GlossError.notAllowed("this book is drm-locked")
                case "cancel": throw CancellationError()
                default: throw ParserFailure()
                }
            }
        }
        let lib = TestLibrary(formats: [Strict()])
        await #expect(throws: GlossError.invalid("it looks damaged, so gloss couldn't read it")) {
            try await lib.services.imports.importData(Data("garbage".utf8), filename: "book.strict")
        }
        // A format's own message, in gloss's copy, reaches the user; cancellation stays cancellation.
        await #expect(throws: GlossError.notAllowed("this book is drm-locked")) {
            try await lib.services.imports.importData(Data("locked".utf8), filename: "book.strict")
        }
        await #expect(throws: CancellationError.self) {
            try await lib.services.imports.importData(Data("cancel".utf8), filename: "book.strict")
        }
        #expect(try await lib.services.library.entries().isEmpty)
        #expect(try await lib.blobs.allHashes().isEmpty)
    }

    @Test("missing titles fall back to the file name")
    func fallbackTitle() async throws {
        let lib = TestLibrary()
        let outcome = try await lib.services.imports.importData(FakeFormat.file(title: nil, author: nil), filename: "notes on camus.fake")
        #expect(outcome.document.title == "notes on camus")
        #expect(outcome.document.author == "")
    }

    @Test("book text is indexed per chapter with locators")
    func bookText() async throws {
        let lib = TestLibrary()
        let (document, _) = try await lib.book(chapters: ["the absurd hero", "sisyphus smiles"])
        let sections = try await lib.services.search.search("sisyphus", in: .document(document.id, [.text]))
        let hit = try #require(sections.first?.hits.first)
        #expect(hit.title == "chapter 2")
        #expect(hit.destination == .bookText(document.id, locator: Locator(scheme: FakeFormat.scheme, value: "section-1"), matchText: "sisyphus"))
    }
}

@Suite("library")
struct LibraryTests {
    @Test("sorting by title ignores case, accents and leading articles")
    func sortByTitle() async throws {
        let lib = TestLibrary()
        for title in ["The Plague", "a Happy Death", "Écrits", "Notebooks"] { _ = try await lib.book(title) }
        let titles = try await lib.services.library.entries(sortedBy: .title).map(\.document.title)
        #expect(titles == ["Écrits", "a Happy Death", "Notebooks", "The Plague"])
    }

    @Test("sorting by author, date added and recency")
    func otherSorts() async throws {
        let lib = TestLibrary()
        let (a, _) = try await lib.book("A", author: "Didion")
        lib.clock.advance(by: 10)
        let (b, _) = try await lib.book("B", author: "Babitz")
        lib.clock.advance(by: 10)
        let (c, _) = try await lib.book("C", author: "")
        #expect(try await lib.services.library.entries(sortedBy: .author).map(\.document.id) == [b.id, a.id, c.id])
        #expect(try await lib.services.library.entries(sortedBy: .dateAdded).map(\.document.id) == [c.id, b.id, a.id])
        lib.clock.advance(by: 10)
        try await lib.services.library.markOpened(a.id)
        #expect(try await lib.services.library.entries(sortedBy: .recent).map(\.document.id) == [a.id, c.id, b.id])
        #expect(try await lib.services.library.recentlyRead().map(\.document.id) == [a.id])
    }

    @Test("shelves filter by format")
    func shelves() async throws {
        struct OtherFormat: DocumentFormat {
            var kind: DocumentKind { DocumentKind("other") }
            var badge: String { "other" }
            var shelf: LibraryShelf { .pdfs }
            var fileExtensions: [String] { ["other"] }
            func sniff(_ prefix: Data) -> Bool { prefix.starts(with: Data("OTHER".utf8)) }
            func readMetadata(from data: Data) throws -> ImportedMetadata { ImportedMetadata(title: "other") }
        }
        let lib = TestLibrary(formats: [FakeFormat(), OtherFormat()])
        _ = try await lib.book()
        _ = try await lib.services.imports.importData(Data("OTHER".utf8), filename: "x.other")
        #expect(try await lib.services.library.entries(shelf: .books).count == 1)
        #expect(try await lib.services.library.entries(shelf: .pdfs).first?.document.title == "other")
        #expect(lib.services.formats.shelves == [.books, .pdfs])
        // Shelves take their first format's symbol; a format that names none gets "doc".
        #expect(lib.services.formats.symbol(of: .books) == "book")
        #expect(lib.services.formats.symbol(of: .pdfs) == "doc")
        #expect(lib.services.formats.symbol(of: LibraryShelf("comics")) == "doc")
    }

    @Test("editing details keeps the root page title in step only if it was untouched")
    func details() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book("Old")
        try await lib.services.library.updateDetails(document.id, title: "New", author: "Someone")
        #expect(try await lib.services.pages.page(root.id)?.title == "New")
        try await lib.services.pages.rename(root.id, to: "my reading notes")
        try await lib.services.library.updateDetails(document.id, title: "Newer")
        #expect(try await lib.services.pages.page(root.id)?.title == "my reading notes")
        #expect(try await lib.services.search.search("someone", in: .library).count == 1)
    }

    @Test("covers: custom first, then the file's, then none")
    func covers() async throws {
        let lib = TestLibrary()
        let outcome = try await lib.services.imports.importData(FakeFormat.file(cover: true), filename: "c.fake")
        let id = outcome.document.id
        #expect(try await lib.services.library.cover(of: id)?.mimeType == "image/png")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        try await lib.services.library.setCover(id, imageData: jpeg)
        #expect(try await lib.services.library.cover(of: id) == CoverImage(data: jpeg, mimeType: "image/jpeg"))
        try await lib.services.library.setCover(id, imageData: nil)
        #expect(try await lib.services.library.cover(of: id)?.mimeType == "image/png")
        let (plain, _) = try await lib.book("no cover")
        #expect(try await lib.services.library.cover(of: plain.id) == nil)
    }

    @Test("reading positions are remembered and clamped")
    func positions() async throws {
        let lib = TestLibrary()
        let (document, _) = try await lib.book()
        let locator = Locator(scheme: FakeFormat.scheme, value: "p")
        try await lib.services.library.savePosition(locator, progression: 1.4, label: "chapter 9", of: document.id)
        let position = try #require(try await lib.services.library.position(of: document.id))
        #expect(position.progression == 1)
        #expect(try await lib.services.library.entries().first?.progress == 1)
    }
}

@Suite("import candidates")
struct ImportCandidateTests {
    @Test("folders expand once each, even with symlink loops")
    func symlinkLoops() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-candidates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("book.epub"))
        try Data("x".utf8).write(to: root.appendingPathComponent("top.pdf"))
        // b/loop → root: following it naively never ends.
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("loop"), withDestinationURL: root)
        let found = ImportCandidates.expand(root, supportedExtensions: ["epub", "pdf"])
        #expect(found.map(\.lastPathComponent).sorted() == ["book.epub", "top.pdf"])
    }
}
