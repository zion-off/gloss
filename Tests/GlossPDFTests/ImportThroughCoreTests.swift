import Foundation
import Testing
import GlossCore
import GlossTestSupport
@testable import GlossPDF

/// The whole import pipeline over a real generated PDF: detect → metadata → text index → search.
@Suite("pdf through the core services")
struct PDFImportThroughCoreTests {
    @Test("a generated pdf imports, indexes and searches like any book")
    func imports() async throws {
        var builder = PDFTestBuilder()
        let content = "BT /F1 12 Tf 72 720 Td (the whale swims on) Tj ET"
        let contents = builder.addStream("", data: Data(content.utf8))
        let font = builder.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        let info = builder.add("<< /Title (Moby-Dick) /Author (Herman Melville) >>")
        let pages = builder.reserve()
        let page = builder.add("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        builder.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
        let data = try builder.build(root: catalog, info: info)

        let lib = TestLibrary(formats: [PDFFormat()])
        let outcome = try await lib.services.imports.importData(data, filename: "moby.pdf")
        guard case .imported(let document) = outcome else { Issue.record("expected an import"); return }
        #expect(document.kind == .pdf)
        #expect(document.title == "Moby-Dick")
        #expect(document.author == "Herman Melville")
        #expect(document.metadata.pageCount == 1)
        #expect(document.metadata.language == nil)

        let hits = try await lib.services.search.search("whale", in: .document(document.id, [.text]))
        let hit = try #require(hits.first?.hits.first)
        #expect(hit.title == "page 1")
        #expect(hit.destination == .bookText(document.id, locator: Locator(scheme: PDFLocators.pageScheme, value: "0"), matchText: "whale"))
        #expect(hit.snippet.segments.filter(\.isMatch) == [.init(text: "whale", isMatch: true)])

        // The format offers no cover of its own; the library says "none" until the app registers a renderer.
        #expect(try await lib.services.library.cover(of: document.id) == nil)
        #expect(lib.services.formats.shelf(of: document.kind) == .pdfs)
        #expect(lib.services.formats.badge(of: document.kind) == "pdf")
    }
}
