import Foundation
import GlossArchive
import GlossCore
import GlossPDF

/// Writes small, valid PDFs with a correct xref table so tests need no binary fixtures.
struct PDFTestBuilder {
    private var bodies: [Data] = []

    /// Appends an object body; returns its object number.
    @discardableResult
    mutating func add(_ body: String) -> Int {
        bodies.append(Data(body.utf8))
        return bodies.count
    }

    /// Appends a stream object; `extra` carries dictionary keys after `/Length`
    /// (e.g. `"/Filter /FlateDecode"`).
    @discardableResult
    mutating func addStream(_ extra: String = "", data: Data) -> Int {
        bodies.append(streamBody(extra, data: data))
        return bodies.count
    }

    /// Reserves an object number now and fills it later with `set`.
    @discardableResult
    mutating func reserve() -> Int {
        bodies.append(Data())
        return bodies.count
    }

    mutating func set(_ number: Int, _ body: String) {
        bodies[number - 1] = Data(body.utf8)
    }

    mutating func setStream(_ number: Int, _ extra: String, data: Data) {
        bodies[number - 1] = streamBody(extra, data: data)
    }

    private func streamBody(_ extra: String, data: Data) -> Data {
        var body = Data("<< /Length \(data.count)".utf8)
        if !extra.isEmpty { body += Data(" \(extra)".utf8) }
        body += Data(" >>\nstream\n".utf8)
        body += data
        body += Data("\nendstream".utf8)
        return body
    }

    /// Assembles the file: header, objects, xref table, trailer, startxref.
    func build(root: Int, info: Int? = nil, trailerExtra: String = "") -> Data {
        var out = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D2}\n".utf8)
        var offsets: [Int] = []
        for (index, body) in bodies.enumerated() {
            offsets.append(out.count)
            out += Data("\(index + 1) 0 obj\n".utf8)
            out += body
            out += Data("\nendobj\n".utf8)
        }
        let xref = out.count
        out += Data("xref\n0 \(bodies.count + 1)\n".utf8)
        out += Data("0000000000 65535 f \n".utf8)
        for offset in offsets {
            out += Data(String(format: "%010d 00000 n \n", offset).utf8)
        }
        var trailer = "trailer\n<< /Size \(bodies.count + 1) /Root \(root) 0 R"
        if let info { trailer += " /Info \(info) 0 R" }
        trailer += "\(trailerExtra) >>\n"
        out += Data(trailer.utf8)
        out += Data("startxref\n\(xref)\n%%EOF\n".utf8)
        return out
    }
}

// MARK: - Encoding helpers

/// Big-endian UTF-16 bytes of a string.
func utf16BE(_ string: String) -> Data {
    var out = Data()
    for unit in string.utf16 {
        out.append(UInt8(unit >> 8))
        out.append(UInt8(unit & 0xFF))
    }
    return out
}

/// A PDF hex string `<…>` of raw bytes.
func pdfHexString(_ data: Data) -> String {
    "<" + data.map { String(format: "%02X", $0) }.joined() + ">"
}

/// A PDF text string with a UTF-16BE BOM, as a hex string.
func pdfUTF16String(_ string: String) -> String {
    pdfHexString(Data([0xFE, 0xFF]) + utf16BE(string))
}

/// A PDF text string with a UTF-8 BOM, as a hex string.
func pdfUTF8String(_ string: String) -> String {
    pdfHexString(Data([0xEF, 0xBB, 0xBF]) + Data(string.utf8))
}

/// PNG "Up" predictor encoding (tag 2 per row), for xref/object streams in tests.
func pngUpEncode(_ data: Data, columns: Int) -> Data {
    var out = Data()
    var previous = [UInt8](repeating: 0, count: columns)
    let bytes = [UInt8](data)
    var i = 0
    while i < bytes.count {
        let end = min(i + columns, bytes.count)
        let row = [UInt8](bytes[i..<end]) + [UInt8](repeating: 0, count: columns - (end - i))
        out.append(2)
        for j in 0..<columns { out.append(row[j] &- previous[j]) }
        previous = row
        i = end
    }
    return out
}

/// TIFF predictor 2 encoding (subtract the sample `colors` bytes left in the row).
func tiff2Encode(_ data: Data, columns: Int, colors: Int) -> Data {
    let rowLength = columns * colors
    var out = Data()
    let bytes = [UInt8](data)
    var i = 0
    while i + rowLength <= bytes.count {
        for j in 0..<rowLength {
            out.append(j >= colors ? bytes[i + j] &- bytes[i + j - colors] : bytes[i + j])
        }
        i += rowLength
    }
    if i < bytes.count { out.append(contentsOf: bytes[i...]) }
    return out
}

/// ASCII85 encoding with the `<~` … `~>` delimiters.
func ascii85Encode(_ data: Data) -> String {
    let bytes = [UInt8](data)
    var out = ""
    var i = 0
    while i < bytes.count {
        let take = min(4, bytes.count - i)
        var value: UInt32 = 0
        for k in 0..<4 { value = (value << 8) | (k < take ? UInt32(bytes[i + k]) : 0) }
        if take == 4, value == 0 {
            out += "z"
        } else {
            var digits = [UInt8]()
            var v = value
            for _ in 0..<5 { digits.append(UInt8(v % 85)); v /= 85 }
            for digit in digits.reversed() { out.append(Character(UnicodeScalar(0x21 + digit))) }
            if take < 4 { out = String(out.dropLast(4 - take)) }
        }
        i += 4
    }
    return "<~" + out + "~>"
}

// MARK: - Document helpers

/// A one-page PDF whose content stream is `content`, with a Type1 font `F1`.
func makePDF(
    content: String,
    compress: Bool = false,
    encoding: String = "/WinAnsiEncoding",
    contentFilter: String? = nil
) throws -> Data {
    var builder = PDFTestBuilder()
    let contentData = Data(content.utf8)
    let filter = contentFilter ?? (compress ? "/Filter /FlateDecode" : "")
    let contents = builder.addStream(filter, data: compress && contentFilter == nil
        ? try Deflate.zlib(contentData)
        : contentData)
    let font = builder.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding \(encoding) >>")
    let pages = builder.reserve()
    let page = builder.add("<< /Type /Page /Parent \(pages) 0 R /Contents \(contents) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
    builder.set(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
    let catalog = builder.add("<< /Type /Catalog /Pages \(pages) 0 R >>")
    return builder.build(root: catalog)
}

/// Extracts text chunks from a PDF, failing the test on a throw.
func extractChunks(_ data: Data) throws -> [TextChunk] {
    try PDFFormat().extractText(from: data)
}

/// The extracted text of all chunks joined with "|".
func extractedText(_ data: Data) throws -> String {
    try extractChunks(data).map(\.text).joined(separator: "|")
}
