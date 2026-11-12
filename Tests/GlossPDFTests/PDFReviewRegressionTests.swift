import Foundation
import Testing
@testable import GlossPDF

/// Regressions from the first independent review (docs/REVIEWS.md, review 1).
@Suite("pdf review regressions")
struct PDFReviewRegressionTests {
    func metadataTitle(_ text: String) throws -> String? {
        try PDFFormat().readMetadata(from: Data(text.utf8)).title
    }

    @Test("hostile inputs parse in linear time", arguments: [
        ("unterminated strings", "("),
        ("unterminated hex strings", "<"),
        ("dictionary openers", "<<"),
        ("array openers", "["),
        ("object headers", "1 0 obj "),
        ("headers opening strings", "1 0 obj ("),
        ("digits", "7"),
    ])
    func hostile(_ name: String, _ unit: String) throws {
        let data = Data(("%PDF-1.7\n" + String(repeating: unit, count: 1_000_000 / unit.utf8.count)).utf8)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = try? PDFFormat().readMetadata(from: data)
            _ = try? PDFFormat().extractText(from: data)
        }
        // Debug builds; quadratic behaviour took hours at this size.
        #expect(elapsed < .seconds(20), "\(name): \(elapsed)")
    }

    @Test("a loose redefinition after an object stream wins")
    func looseAfterObjectStream() throws {
        let member = "<< /Title (old title) >>"
        let header = "2 0 "
        let streamBody = header + member
        let pdf = """
        %PDF-1.7
        1 0 obj << /Type /Catalog /Pages 3 0 R >> endobj
        3 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj
        4 0 obj << /Type /ObjStm /N 1 /First \(header.utf8.count) /Length \(streamBody.utf8.count) >>
        stream
        \(streamBody)
        endstream
        endobj
        2 0 obj << /Title (new title) >> endobj
        trailer << /Root 1 0 R /Info 2 0 R >>
        %%EOF
        """
        #expect(try metadataTitle(pdf) == "new title")
    }

    @Test("an object stream after a loose definition wins")
    func objectStreamAfterLoose() throws {
        let streamBody = "2 0 << /Title (new title) >>"
        let pdf = """
        %PDF-1.7
        1 0 obj << /Type /Catalog /Pages 3 0 R >> endobj
        2 0 obj << /Title (old title) >> endobj
        3 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj
        4 0 obj << /Type /ObjStm /N 1 /First 4 /Length \(streamBody.utf8.count) >>
        stream
        \(streamBody)
        endstream
        endobj
        trailer << /Root 1 0 R /Info 2 0 R >>
        %%EOF
        """
        #expect(try metadataTitle(pdf) == "new title")
    }

    @Test("the xref stream latest in the file decides /Info")
    func latestXRefStreamWins() throws {
        var pdf = """
        %PDF-1.7
        1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj
        3 0 obj << /Title (stale) >> endobj
        4 0 obj << /Title (current) >> endobj

        """
        // Twenty incremental updates; only the last points at the current /Info. With the
        // old dictionary-order bug the chance of picking it was about 1 in 20.
        for update in 0..<20 {
            let info = update == 19 ? 4 : 3
            pdf += "\(10 + update) 0 obj << /Type /XRef /Root 1 0 R /Info \(info) 0 R /Size 40 /W [1 1 1] /Length 0 >>\nstream\n\nendstream\nendobj\n"
        }
        #expect(try metadataTitle(pdf) == "current")
    }

    @Test("a later trailer keyword beats an earlier xref stream")
    func trailerAfterXRefStream() throws {
        let pdf = """
        %PDF-1.7
        1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj
        3 0 obj << /Title (from the xref stream) >> endobj
        4 0 obj << /Title (from the trailer) >> endobj
        5 0 obj << /Type /XRef /Root 1 0 R /Info 3 0 R /Size 6 /W [1 1 1] /Length 0 >>
        stream

        endstream
        endobj
        trailer << /Root 1 0 R /Info 4 0 R >>
        %%EOF
        """
        #expect(try metadataTitle(pdf) == "from the trailer")
    }

    @Test("pages with different direct fonts under one name each decode with their own")
    func directFontsAreNotShared() throws {
        // Page 1's F1 maps byte 0x41 to "x" via /Differences; page 2's F1 is plain WinAnsi.
        let content = "BT /F1 12 Tf 72 720 Td (A) Tj ET"
        let pdf = """
        %PDF-1.7
        1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        2 0 obj << /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >> endobj
        3 0 obj << /Type /Page /Parent 2 0 R /Contents 5 0 R
          /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica
            /Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [65 /x] >> >> >> >> >> endobj
        4 0 obj << /Type /Page /Parent 2 0 R /Contents 5 0 R
          /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >> >> >> >> endobj
        5 0 obj << /Length \(content.utf8.count) >>
        stream
        \(content)
        endstream
        endobj
        trailer << /Root 1 0 R >>
        %%EOF
        """
        let chunks = try PDFFormat().extractText(from: Data(pdf.utf8))
        #expect(chunks.map(\.text) == ["x", "A"])
    }
}
