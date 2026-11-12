import Foundation
import Testing
@testable import GlossReaderBridge
import GlossCore

@Suite("reader resources")
struct ReaderResourceTests {
    let router = ReaderResourceRouter()
    let id = DocumentID(GlossID(high: 0x7000, low: 42))

    func route(_ string: String) -> ReaderResource { router.route(URL(string: string)!) }

    @Test("reader files route with the right MIME types")
    func files() {
        #expect(route("gloss-reader://app/index.html") == .readerFile(path: "index.html", mimeType: "text/html; charset=utf-8"))
        #expect(route("gloss-reader://app/foliate/view.js") == .readerFile(path: "foliate/view.js", mimeType: "text/javascript; charset=utf-8"))
        #expect(route("gloss-reader://APP/reader.css") == .readerFile(path: "reader.css", mimeType: "text/css; charset=utf-8"))
        #expect(route("gloss-reader://app/glue.js?v=1") == .readerFile(path: "glue.js", mimeType: "text/javascript; charset=utf-8"))
    }

    @Test("books route by document id")
    func books() {
        #expect(route(ReaderResourceRouter.bookURL(id).absoluteString) == .book(id))
        #expect(route("gloss-reader://app/book/not-an-id") == .notFound)
        #expect(route("gloss-reader://app/book/\(id)/extra") == .notFound)
    }

    @Test("traversal, hidden files, other hosts and unknown types are refused")
    func refusals() {
        for url in ["gloss-reader://app/../secret.js", "gloss-reader://app/foliate/../../x.js", "gloss-reader://app/.env",
                    "gloss-reader://app//x.js", "gloss-reader://app/", "gloss-reader://other/index.html",
                    "https://app/index.html", "gloss-reader://app/run.sh", "gloss-reader://app/foliate/VENDORED.md"] {
            #expect(route(url) == .notFound, "\(url)")
        }
    }

    @Test("responses are never cached")
    func headers() {
        #expect(ReaderResourceRouter.headers(mimeType: "text/html", length: 12)
                == ["Content-Type": "text/html", "Content-Length": "12", "Cache-Control": "no-store"])
    }

    @Test("the reader page declares the policy, with the import map's real hash")
    func policy() throws {
        let page = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GlossReaderEPUB/Resources/reader/index.html")
        let html = try String(contentsOf: page, encoding: .utf8)
        let hash = try #require(ReaderPagePolicy.importMapHash(html: html))
        #expect(ReaderPagePolicy.declaredPolicy(html: html) == ReaderPagePolicy.contentSecurityPolicy(importMapHash: hash))
        // The policy must come before any script so it governs all of them.
        let metaAt = try #require(html.range(of: "Content-Security-Policy")).lowerBound
        let firstScript = try #require(html.range(of: "<script")).lowerBound
        #expect(metaAt < firstScript)
        // Book scripts (blob: documents) can't run; only the page's own files and the import map can.
        #expect(!ReaderPagePolicy.contentSecurityPolicy(importMapHash: hash).contains("script-src 'self' blob:"))
        #expect(!ReaderPagePolicy.contentSecurityPolicy(importMapHash: hash).contains("unsafe-eval"))
    }
}
