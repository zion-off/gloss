import Foundation
import Testing
import GlossCore
import GlossEPUB
@testable import GlossReaderBridge
import GlossTestSupport

@Suite("reader resource loader")
final class ReaderResourceLoaderTests {
    let lib = TestLibrary(formats: [EPUBFormat(), FakeFormat()])
    let readerDirectory: URL

    init() throws {
        readerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gloss-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: readerDirectory.appendingPathComponent("foliate/ui"), withIntermediateDirectories: true)
        try Data("<!doctype html>".utf8).write(to: readerDirectory.appendingPathComponent("index.html"))
        try Data("export {}".utf8).write(to: readerDirectory.appendingPathComponent("foliate/view.js"))
    }

    deinit {
        try? FileManager.default.removeItem(at: readerDirectory)
    }

    var loader: ReaderResourceLoader { ReaderResourceLoader(readerDirectory: readerDirectory, library: lib.services.library) }

    func load(_ string: String) async -> ReaderResponse { await loader.response(for: URL(string: string)!) }

    @Test("reader files come from the reader directory, typed and uncached")
    func readerFiles() async {
        let page = await load("gloss-reader://app/index.html")
        #expect(page.statusCode == 200)
        #expect(page.body == Data("<!doctype html>".utf8))
        #expect(page.headers == ["Content-Type": "text/html; charset=utf-8", "Content-Length": "15", "Cache-Control": "no-store"])

        let script = await load("gloss-reader://app/foliate/view.js")
        #expect(script.statusCode == 200)
        #expect(script.headers["Content-Type"] == "text/javascript; charset=utf-8")
        #expect(script.body == Data("export {}".utf8))
    }

    @Test("missing files, directories and refused routes are 404s with an empty body")
    func missing() async {
        for url in ["gloss-reader://app/missing.js", "gloss-reader://app/foliate/ui.js", "gloss-reader://app/../index.html",
                    "gloss-reader://other/index.html", "gloss-reader://app/book/not-an-id"] {
            let response = await load(url)
            #expect(response.statusCode == 404, "\(url)")
            #expect(response.body.isEmpty, "\(url)")
            #expect(response.headers["Content-Length"] == "0", "\(url)")
        }
    }

    @Test("a live EPUB is served from the blob store")
    func book() async throws {
        let bytes = try EPUBBuilder().build()
        let document = try await lib.services.imports.importData(bytes, filename: "stranger.epub").document

        let response = await loader.response(for: ReaderResourceRouter.bookURL(document.id))
        #expect(response.statusCode == 200)
        #expect(response.body == bytes)
        #expect(response.headers == ["Content-Type": "application/epub+zip", "Content-Length": String(bytes.count), "Cache-Control": "no-store"])
    }

    @Test("trashed books, other formats and unknown ids are not served")
    func refusedBooks() async throws {
        let epub = try await lib.services.imports.importData(try EPUBBuilder().build(), filename: "stranger.epub").document
        let (fake, _) = try await lib.book("Not An EPUB")
        _ = try await lib.services.trash.trash(.document, id: epub.id.stringValue)

        #expect(await loader.response(for: ReaderResourceRouter.bookURL(epub.id)) == .notFound)
        #expect(await loader.response(for: ReaderResourceRouter.bookURL(fake.id)) == .notFound)
        #expect(await loader.response(for: ReaderResourceRouter.bookURL(DocumentID(GlossID(high: 1, low: 2)))) == .notFound)
    }

    @Test("a book whose bytes went missing is a 404, not a crash")
    func missingBlob() async throws {
        let document = try await lib.services.imports.importData(try EPUBBuilder().build(), filename: "stranger.epub").document
        try await lib.blobs.delete(document.contentHash)

        #expect(await loader.response(for: ReaderResourceRouter.bookURL(document.id)) == .notFound)
    }
}
