import Foundation
import Testing
import GlossArchive
import GlossPDF

@Suite("PDF robustness")
struct PDFRobustnessTests {
    let format = PDFFormat()

    /// A PDF exercising most paths: Flate content, a Form XObject, an inline image,
    /// a Type0 font with ToUnicode, Info metadata and an XMP packet.
    private func kitchenSink() throws -> Data {
        var builder = PDFTestBuilder()
        let font = builder.reserve()
        let toUnicode = builder.reserve()
        let form = builder.addStream(
            "/Type /XObject /Subtype /Form /BBox [0 0 200 50] /Resources << /Font << /F1 \(font) 0 R >> >>",
            data: Data("BT /F1 10 Tf 2 2 Td (form body) Tj ET".utf8))
        let cmap = """
        /CIDInit /ProcSet findresource begin
        begincodespacerange
        <0000> <ffff>
        endcodespacerange
        1 beginbfchar
        <0041> <0061>
        endbfchar
        end
        """
        builder.setStream(toUnicode, "", data: Data(cmap.utf8))
        builder.set(font, "<< /Type /Font /Subtype /Type0 /BaseFont /Custom /Encoding /Identity-H /DescendantFonts [<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Custom >>] /ToUnicode \(toUnicode) 0 R >>")
        let flateContent = try Deflate.zlib(Data("BT /F1 12 Tf 72 700 Td (flate page body) Tj ET".utf8))
        let flate = builder.addStream("/Filter /FlateDecode", data: flateContent)
        let inline = builder.addStream(data: Data("q BI /W 2 /H 2 /CS /G /BPC 8 ID 1234 EI Q BT /F1 12 Tf 72 700 Td (inline page body) Tj ET".utf8))
        let type0Content = builder.addStream(data: Data("BT /F1 12 Tf 72 700 Td (\\000A\\000A) Tj ET".utf8))
        let formContent = builder.addStream(data: Data("q /Fm1 Do Q BT /F1 12 Tf 72 700 Td (xobject page body) Tj ET".utf8))
        let pages = builder.reserve()
        var kids: [String] = []
        for contents in [flate, inline, type0Content, formContent] {
            kids.append("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R /Resources << /Font << /F1 \(font) 0 R >> /XObject << /Fm1 \(form) 0 R >> >> >>")
        }
        builder.set(pages, "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count 4 >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
        let info = builder.add("<< /Title (Kitchen Sink) /Author (Test) >>")
        return builder.build(root: catalog, info: info)
    }

    @Test("truncation and corruption at many offsets never crash or hang")
    func survivesDamage() throws {
        let pdf = try kitchenSink()
        let clock = ContinuousClock()
        let start = clock.now

        // Truncation: every ~1/120th of the file, plus the very first bytes.
        for cut in [0, 1, 5] + stride(from: 8, to: pdf.count, by: max(1, pdf.count / 120)) {
            let truncated = Data(pdf.prefix(cut))
            _ = try? format.readMetadata(from: truncated)
            _ = try? format.extractText(from: truncated)
        }

        // Corruption: flip bits at every 7th byte.
        for offset in stride(from: 0, to: pdf.count, by: 7) {
            var corrupted = pdf
            corrupted[offset] ^= 0x5A
            _ = try? format.readMetadata(from: corrupted)
            _ = try? format.extractText(from: corrupted)
        }

        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .seconds(60))
    }

    @Test("a large file is handled without quadratic blowup")
    func largeFile() throws {
        // 400 pages with ~10 KB of uncompressed content each (a 4 MB file to scan).
        var builder = PDFTestBuilder()
        let font = builder.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        let pages = builder.reserve()
        var kids: [String] = []
        let line = "BT /F1 10 Tf 72 700 Td (the myth of sisyphus) Tj T* (and again) Tj ET\n"
        let body = Data(String(repeating: line, count: 200).utf8)
        for _ in 0..<400 {
            let contents = builder.addStream(data: body)
            kids.append("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        }
        builder.set(pages, "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count 400 >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
        let pdf = builder.build(root: catalog)
        #expect(pdf.count > 1_000_000)

        let clock = ContinuousClock()
        let start = clock.now
        let metadata = try format.readMetadata(from: pdf)
        #expect(metadata.metadata.pageCount == 400)
        let chunks = try format.extractText(from: pdf)
        #expect(chunks.count == 400)
        #expect(chunks[0].text.hasPrefix("the myth of sisyphus"))
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .seconds(30))
    }

    @Test("empty and header-only data")
    func degenerateInput() {
        _ = try? format.readMetadata(from: Data())
        _ = try? format.extractText(from: Data())
        _ = try? format.readMetadata(from: Data("%PDF-1.7".utf8))
        _ = try? format.extractText(from: Data("%PDF-1.7".utf8))
        _ = try? format.readMetadata(from: Data("%PDF-1.7\n1 0 obj".utf8))
        _ = try? format.extractText(from: Data("%PDF-1.7\nbroken beyond repair".utf8))
    }
}
