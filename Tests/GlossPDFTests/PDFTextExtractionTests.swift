import Foundation
import Testing
import GlossCore
import GlossArchive
import GlossPDF

@Suite("PDF text extraction")
struct PDFTextExtractionTests {
    let format = PDFFormat()

    @Test("extracts text from an uncompressed content stream with locator and label")
    func uncompressedText() throws {
        let data = try makePDF(content: "BT /F1 12 Tf 72 720 Td (Hello world) Tj ET")
        let chunks = try extractChunks(data)
        #expect(chunks.count == 1)
        #expect(chunks[0].locator.scheme == PDFLocators.pageScheme)
        #expect(chunks[0].locator.value == "0")
        #expect(chunks[0].label == "page 1")
        #expect(chunks[0].text == "Hello world")
    }

    @Test("orders multi-page chunks and skips pages with no text")
    func multiPageOrdering() throws {
        var builder = PDFTestBuilder()
        let font = builder.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        let pages = builder.reserve()
        var kids: [String] = []
        for index in 0..<3 {
            // Page 2 (index 1) has a content stream with no text.
            let body = index == 1 ? "q Q" : "BT /F1 12 Tf 72 700 Td (page \(index + 1) body) Tj ET"
            let contents = builder.addStream(data: Data(body.utf8))
            kids.append("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        }
        builder.set(pages, "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count 3 >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
        let chunks = try extractChunks(builder.build(root: catalog))
        #expect(chunks.map(\.locator.value) == ["0", "2"])
        #expect(chunks.map { $0.label ?? "" } == ["page 1", "page 3"])
        #expect(chunks.map(\.text) == ["page 1 body", "page 3 body"])
    }

    @Test("extracts text from Flate-compressed content streams")
    func flateContent() throws {
        let data = try makePDF(content: "BT /F1 12 Tf 72 720 Td (compressed hello) Tj ET", compress: true)
        #expect(try extractedText(data) == "compressed hello")
    }

    @Test("TJ kerning and positioning operators produce spaces and line breaks")
    func tjSpacingAndLineBreaks() throws {
        let content = """
        BT /F1 12 Tf 72 720 Td [(Kerned) -80 (tight)] TJ 0 -20 Td [(Word) -250 (gap)] TJ ET
        BT /F1 12 Tf 12 TL 72 640 Td (first line) Tj T* (second line) Tj ET
        BT /F1 12 Tf 1 0 0 1 72 560 Tm (top) Tj 1 0 0 1 72 540 Tm (bottom) Tj 1 0 0 1 300 540 Tm (right) Tj ET
        """
        let data = try makePDF(content: content)
        #expect(try extractedText(data) == "Kernedtight\nWord gap\nfirst line\nsecond line\ntop\nbottom right")
    }

    @Test("decodes WinAnsi and /Differences glyph names")
    func winAnsiAndDifferences() throws {
        // WinAnsi high byte: café's é is 0xE9 (\351).
        let winAnsiData = try makePDF(content: "BT /F1 12 Tf 72 720 Td (caf\\351 cr\\350me) Tj ET")
        #expect(try extractedText(winAnsiData) == "café crème")

        // Differences: byte 24 (octal \030) → emdash, 'A' → uni2764 (❤).
        var builder = PDFTestBuilder()
        let contents = builder.addStream(data: Data("BT /F1 12 Tf 72 700 Td (before\\030after A) Tj ET".utf8))
        let font = builder.add("<< /Type /Font /Subtype /Type1 /BaseFont /Custom /Encoding << /BaseEncoding /WinAnsiEncoding /Differences [24 /emdash 65 /uni2764] >> >>")
        let pages = builder.reserve()
        let page = builder.add("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        builder.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
        #expect(try extractedText(builder.build(root: catalog)) == "before—after ❤")
    }

    @Test("decodes a Type0 font through a ToUnicode CMap (bfchar, bfrange, array form)")
    func toUnicodeCMap() throws {
        let cmap = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincodespacerange
        <0000> <ffff>
        endcodespacerange
        2 beginbfchar
        <0041> <005a>
        <0042> <00e9>
        endbfchar
        1 beginbfrange
        <0043> <0045> <0061>
        endbfrange
        1 beginbfrange
        <0046> <0047> [<0064> <0153>]
        endbfrange
        CMapName currentdict /CMap defineresource pop
        end
        end
        """
        var builder = PDFTestBuilder()
        let toUnicode = builder.addStream(data: Data(cmap.utf8))
        let descendant = builder.add("<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Custom /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> >>")
        let font = builder.add("<< /Type /Font /Subtype /Type0 /BaseFont /Custom /Encoding /Identity-H /DescendantFonts [\(descendant) 0 R] /ToUnicode \(toUnicode) 0 R >>")
        let contents = builder.addStream(data: Data("BT /F1 12 Tf 72 720 Td (\\000A\\000B\\000C\\000D\\000E\\000F\\000G) Tj ET".utf8))
        let pages = builder.reserve()
        let page = builder.add("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        builder.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
        // 0041→Z, 0042→é, 0043-0045→a b c, 0046→d, 0047→œ.
        #expect(try extractedText(builder.build(root: catalog)) == "Zéabcdœ")
    }

    @Test("recurses into Form XObjects with their own resources")
    func formXObjects() throws {
        var builder = PDFTestBuilder()
        let font = builder.reserve()
        let form = builder.addStream(
            "/Type /XObject /Subtype /Form /BBox [0 0 200 50] /Resources << /Font << /F1 \(font) 0 R >> >>",
            data: Data("BT /F1 10 Tf 2 2 Td (form text) Tj ET".utf8))
        let contents = builder.addStream(data: Data("q 1 0 0 1 72 600 cm /Fm1 Do Q BT /F1 12 Tf 72 720 Td (page text) Tj ET".utf8))
        builder.set(font, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let pages = builder.reserve()
        let page = builder.add("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R /Resources << /Font << /F1 \(font) 0 R >> /XObject << /Fm1 \(form) 0 R >> >> >>")
        builder.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
        #expect(try extractedText(builder.build(root: catalog)) == "form text\npage text")
    }

    @Test("reads objects from object streams and the root from an xref stream")
    func objectStreamsAndXRefStreams() throws {
        // Objects 1-4 live in object stream 6 (Flate + TIFF predictor 2);
        // the content stream (5) is loose; the xref stream (7) uses a PNG Up predictor.
        let content = "BT /F1 12 Tf 72 700 Td (from object streams) Tj ET"
        let contentCompressed = try Deflate.zlib(Data(content.utf8))

        var bodies: [(Int, String)] = []
        bodies.append((1, "<< /Type /Catalog /Pages 2 0 R >>"))
        bodies.append((2, "<< /Type /Pages /Kids [3 0 R] /Count 1 /Resources << /Font << /F1 4 0 R >> >> >>"))
        bodies.append((3, "<< /Type /Page /Parent 2 0 R /Contents 5 0 R >>"))
        bodies.append((4, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"))
        var pairs = ""
        var bodyText = ""
        var cursor = 0
        for (number, body) in bodies {
            pairs += "\(number) \(cursor) "
            bodyText += body + "\n"
            cursor += body.count + 1
        }
        let first = pairs.count
        let payload = try Deflate.zlib(tiff2Encode(Data((pairs + bodyText).utf8), columns: 3, colors: 3))

        var out = Data("%PDF-1.7\n".utf8)
        let offset5 = out.count
        out += Data("5 0 obj\n<< /Length \(contentCompressed.count) /Filter /FlateDecode >>\nstream\n".utf8)
        out += contentCompressed
        out += Data("\nendstream\nendobj\n".utf8)
        let offset6 = out.count
        out += Data("6 0 obj\n<< /Type /ObjStm /N 4 /First \(first) /Length \(payload.count) /Filter /FlateDecode /DecodeParms << /Predictor 2 /Columns 3 /Colors 3 >> >>\nstream\n".utf8)
        out += payload
        out += Data("\nendstream\nendobj\n".utf8)

        let offset7 = out.count
        var xref = Data()
        func entry(_ type: Int, _ field: UInt32, _ generation: UInt32) {
            xref.append(UInt8(type))
            for shift in stride(from: 24, through: 0, by: -8) {
                xref.append(UInt8((field >> UInt32(shift)) & 0xFF))
            }
            xref.append(UInt8((generation >> 8) & 0xFF))
            xref.append(UInt8(generation & 0xFF))
        }
        entry(0, 0, 65535)
        for index in 0..<4 { entry(2, 6, UInt32(index)) } // objects 1-4 in stream 6
        entry(1, UInt32(offset5), 0)
        entry(1, UInt32(offset6), 0)
        entry(1, UInt32(offset7), 0)
        let xrefData = try Deflate.zlib(pngUpEncode(xref, columns: 7))
        out += Data("7 0 obj\n<< /Type /XRef /Size 8 /W [1 4 2] /Root 1 0 R /Length \(xrefData.count) /Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns 7 >> >>\nstream\n".utf8)
        out += xrefData
        out += Data("\nendstream\nendobj\nstartxref\n\(offset7)\n%%EOF".utf8)

        let chunks = try extractChunks(out)
        #expect(chunks.map(\.text) == ["from object streams"]) // resources inherited from the Pages node
        let metadata = try format.readMetadata(from: out)
        #expect(metadata.metadata.pageCount == 1)
    }

    @Test("inherits resources from the Pages node")
    func inheritedResources() throws {
        var builder = PDFTestBuilder()
        let font = builder.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let pages = builder.reserve()
        var kids: [String] = []
        for index in 0..<2 {
            let contents = builder.addStream(data: Data("BT /F1 12 Tf 72 \(700 - index * 20) Td (inherited \(index)) Tj ET".utf8))
            kids.append("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R >>")
        }
        builder.set(pages, "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count 2 /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
        #expect(try extractedText(builder.build(root: catalog)) == "inherited 0|inherited 1")
    }

    @Test("decodes ASCIIHexDecode and ASCII85Decode content streams")
    func asciiFilters() throws {
        let hexContent = "BT /F1 12 Tf 72 720 Td (hex filtered) Tj ET"
        let hex = Data(hexContent.utf8).map { String(format: "%02x", $0) }.joined() + ">"
        let hexPDF = try makeFilteredPDF(filter: "/Filter /ASCIIHexDecode", data: Data(hex.utf8))
        #expect(try extractedText(hexPDF) == "hex filtered")

        let a85Content = "BT /F1 12 Tf 72 720 Td (a85 filtered) Tj ET"
        let a85PDF = try makeFilteredPDF(filter: "/Filter /ASCII85Decode", data: Data(ascii85Encode(Data(a85Content.utf8)).utf8))
        #expect(try extractedText(a85PDF) == "a85 filtered")
    }

    @Test("skips streams with unknown filters without crashing")
    func unknownFilter() throws {
        var builder = PDFTestBuilder()
        let font = builder.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let pages = builder.reserve()
        var kids: [String] = []
        let badContents = builder.addStream("/Filter /DCTDecode", data: Data(repeating: 0xAB, count: 64))
        kids.append("<< /Type /Page /Parent \(pages) 0 R /Contents \(badContents) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        let goodContents = builder.addStream(data: Data("BT /F1 12 Tf 72 700 Td (good page) Tj ET".utf8))
        kids.append("<< /Type /Page /Parent \(pages) 0 R /Contents \(goodContents) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        builder.set(pages, "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count 2 >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
        #expect(try extractedText(builder.build(root: catalog)) == "good page")
    }

    @Test("later definitions of the same object number win")
    func laterDefinitionsWin() throws {
        var data = try makePDF(content: "BT /F1 12 Tf 72 720 Td (first revision) Tj ET")
        // Incremental update: redefine object 1 (the content stream) at the end of the file.
        let text = "BT /F1 12 Tf 72 720 Td (second revision) Tj ET"
        var update = Data("\n1 0 obj\n<< /Length \(text.utf8.count) >>\nstream\n".utf8)
        update += Data(text.utf8)
        update += Data("\nendstream\nendobj\ntrailer\n<< /Size 6 /Root 5 0 R >>\nstartxref\n0\n%%EOF\n".utf8)
        data += update
        #expect(try extractedText(data) == "second revision")
    }

    @Test("skips inline images safely")
    func inlineImages() throws {
        let content = """
        q 1 0 0 1 0 0 cm
        BI /W 2 /H 2 /CS /G /BPC 8 ID \u{00}\u{01}\u{7F}\u{FF} EI Q
        % a comment between graphics and text
        BT /F1 12 Tf 72 720 Td (after image) Tj ET
        """
        let data = try makePDF(content: content)
        #expect(try extractedText(data) == "after image")
    }


    @Test("applies filter arrays in order")
    func filterArrays() throws {
        // The stream holds hex of flate-compressed bytes; filters run in array order.
        let content = "BT /F1 12 Tf 72 720 Td (array filtered) Tj ET"
        let compressed = try Deflate.zlib(Data(content.utf8))
        let hex = compressed.map { String(format: "%02X", $0) }.joined() + ">"
        var builder = PDFTestBuilder()
        let contents = builder.addStream("/Filter [/ASCIIHexDecode /FlateDecode]", data: Data(hex.utf8))
        let font = builder.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let pages = builder.reserve()
        let page = builder.add("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        builder.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
        #expect(try extractedText(builder.build(root: catalog)) == "array filtered")
    }

    @Test("the ' and \" operators move to the next line before showing")
    func nextLineOperators() throws {
        let content = """
        BT /F1 12 Tf 12 TL 72 720 Td (first)' (second)' 3 3 (third) " ET
        """
        let data = try makePDF(content: content)
        #expect(try extractedText(data) == "first\nsecond\nthird")
    }

    /// A one-page PDF whose content stream is `data` with `filter` in the dictionary.
    private func makeFilteredPDF(filter: String, data: Data) throws -> Data {
        var builder = PDFTestBuilder()
        let contents = builder.addStream(filter, data: data)
        let font = builder.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let pages = builder.reserve()
        let page = builder.add("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        builder.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
        return builder.build(root: catalog)
    }
}
