import Foundation
import Testing
import GlossArchive
import GlossCore
import GlossPDF

@Suite("PDF metadata")
struct PDFFormatMetadataTests {
    let format = PDFFormat()

    @Test("sniffs %PDF- within the first 1024 bytes, and only there")
    func sniffing() {
        #expect(format.sniff(Data("%PDF-1.7\nrest".utf8)))
        #expect(!format.sniff(Data("plain text, no marker".utf8)))
        #expect(format.sniff(Data(repeating: 0x0A, count: 200) + Data("%PDF-1.7\n".utf8)))
        #expect(!format.sniff(Data(repeating: 0x0A, count: 2000) + Data("%PDF-1.7\n".utf8)))
        #expect(!format.sniff(Data()))
    }

    @Test("throws only for files that are not PDFs")
    func nonPDFThrows() {
        #expect(throws: PDFError.notAPDF) {
            try format.readMetadata(from: Data("FAKEDOC\nnot a pdf".utf8))
        }
        #expect(throws: PDFError.notAPDF) {
            try format.extractText(from: Data("FAKEDOC\nnot a pdf".utf8))
        }
    }

    @Test("reads title and author from Info (PDFDocEncoding)")
    func infoPDFDocEncoding() throws {
        // \351 is the octal escape for é (0xE9) in a PDF literal string.
        let data = try makeInfoPDF(title: "(Caf\\351 au lait)", author: "(Simone de Beauvoir)")
        let metadata = try format.readMetadata(from: data)
        #expect(metadata.title == "Café au lait")
        #expect(metadata.author == "Simone de Beauvoir")
        #expect(metadata.metadata.pageCount == 1)
    }

    @Test("reads UTF-16BE Info strings")
    func infoUTF16BE() throws {
        let data = try makeInfoPDF(title: pdfUTF16String("La Peste"), author: pdfUTF16String("Albert Camus"))
        let metadata = try format.readMetadata(from: data)
        #expect(metadata.title == "La Peste")
        #expect(metadata.author == "Albert Camus")
    }

    @Test("reads UTF-8 Info strings with BOM")
    func infoUTF8BOM() throws {
        let data = try makeInfoPDF(title: pdfUTF8String("The Fall"), author: pdfUTF8String("Albert Camus"))
        let metadata = try format.readMetadata(from: data)
        #expect(metadata.title == "The Fall")
        #expect(metadata.author == "Albert Camus")
    }

    @Test("blank Info values become nil")
    func blankInfo() throws {
        let data = try makeInfoPDF(title: "(   )", author: "()")
        let metadata = try format.readMetadata(from: data)
        #expect(metadata.title == nil)
        #expect(metadata.author == nil)
    }

    @Test("falls back to XMP when Info is missing or blank")
    func xmpFallback() throws {
        let xmp = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
              <dc:title><rdf:Alt><rdf:li xml:lang="x-default">XMP Title</rdf:li></rdf:Alt></dc:title>
              <dc:creator><rdf:Seq><rdf:li>Rachel Cusk</rdf:li></rdf:Seq></dc:creator>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        // Missing Info: XMP supplies both.
        let withXmpOnly = try makeXMPDF(xmp: xmp, infoTitle: nil, infoAuthor: nil)
        let fromXmp = try format.readMetadata(from: withXmpOnly)
        #expect(fromXmp.title == "XMP Title")
        #expect(fromXmp.author == "Rachel Cusk")

        // Blank Info values: XMP fills the gaps.
        let withBlankInfo = try makeXMPDF(xmp: xmp, infoTitle: "(  )", infoAuthor: "(x)")
        let filled = try format.readMetadata(from: withBlankInfo)
        #expect(filled.title == "XMP Title")
        #expect(filled.author == "x")

        // Real Info wins over XMP.
        let withInfo = try makeXMPDF(xmp: xmp, infoTitle: "(Info Title)", infoAuthor: "(Info Author)")
        let preferred = try format.readMetadata(from: withInfo)
        #expect(preferred.title == "Info Title")
        #expect(preferred.author == "Info Author")
    }

    @Test("counts pages and reads the catalog language")
    func pageCountAndLanguage() throws {
        var builder = PDFTestBuilder()
        let pages = builder.reserve()
        var kids: [String] = []
        for index in 0..<3 {
            let contents = builder.addStream(data: Data("BT /F1 12 Tf 72 700 Td (page \(index)) Tj ET".utf8))
            kids.append("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R >>")
        }
        builder.set(pages, "<< /Type /Pages /Kids [\(kids.map { "\($0)" }.joined(separator: " "))] /Count 3 >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R /Lang (en-GB) >>")
        let metadata = try format.readMetadata(from: builder.build(root: catalog))
        #expect(metadata.metadata.pageCount == 3)
        #expect(metadata.metadata.language == "en-GB")
    }

    @Test("encrypted files yield no text and no strings, but never throw")
    func encrypted() throws {
        var builder = PDFTestBuilder()
        let contents = builder.addStream(data: Data("BT /F1 12 Tf 72 700 Td (secret) Tj ET".utf8))
        let font = builder.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let pages = builder.reserve()
        let page = builder.add("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        builder.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
        let info = builder.add("<< /Title (Encrypted Title) /Author (Someone) >>")
        let encrypt = builder.add("<< /Filter /Standard /V 1 /R 2 /O (012345678901234567890123) /U (012345678901234567890123) /P -4 >>")
        let data = builder.build(root: catalog, info: info, trailerExtra: " /Encrypt \(encrypt) 0 R")

        let metadata = try format.readMetadata(from: data)
        #expect(metadata.title == nil)
        #expect(metadata.author == nil)
        #expect(metadata.metadata.pageCount == 1) // the page tree is not encrypted
        #expect(try format.extractText(from: data).isEmpty)
    }

    // MARK: Builders

    /// A one-page PDF with an `/Info` dictionary.
    private func makeInfoPDF(title: String, author: String) throws -> Data {
        var builder = PDFTestBuilder()
        let contents = builder.addStream(data: Data("BT /F1 12 Tf 72 700 Td (body) Tj ET".utf8))
        let font = builder.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let pages = builder.reserve()
        let page = builder.add("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        builder.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
        let info = builder.add("<< /Title \(title) /Author \(author) >>")
        return builder.build(root: catalog, info: info)
    }

    /// A one-page PDF with a Flate-compressed XMP `/Metadata` stream and optional Info values.
    private func makeXMPDF(xmp: String, infoTitle: String?, infoAuthor: String?) throws -> Data {
        var builder = PDFTestBuilder()
        let contents = builder.addStream(data: Data("BT /F1 12 Tf 72 700 Td (body) Tj ET".utf8))
        let font = builder.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let pages = builder.reserve()
        let page = builder.add("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        builder.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        let metadata = builder.addStream("/Type /Metadata /Subtype /XML /Filter /FlateDecode", data: try Deflate.zlib(Data(xmp.utf8)))
        var catalogBody = "<< /Type /Catalog /Pages \(pages) 0 R /Metadata \(metadata) 0 R"
        var info: Int?
        if infoTitle != nil || infoAuthor != nil {
            info = builder.add("<< /Title \(infoTitle ?? "()") /Author \(infoAuthor ?? "()") >>")
        }
        catalogBody += " >>"
        let catalog = builder.add(catalogBody)
        return builder.build(root: catalog, info: info)
    }
}
