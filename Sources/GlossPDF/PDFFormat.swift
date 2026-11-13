import Foundation
import GlossCore

/// Thrown only for data that is not a PDF at all; malformed PDFs never throw.
public enum PDFError: Error, Equatable, Sendable {
    case notAPDF
}

/// The PDF import format: metadata and full-text extraction in pure Swift (Foundation
/// only), used on every platform for import and search. Rendering is PDFKit's job on
/// the Mac and deliberately not part of this module.
public struct PDFFormat: DocumentFormat, TextExtracting {
    public init() {}

    public var kind: DocumentKind { .pdf }
    public var badge: String { "pdf" }
    public var shelf: LibraryShelf { .pdfs }
    public var shelfSymbol: String { "doc.richtext" }
    public var fileExtensions: [String] { ["pdf"] }

    /// `%PDF-` anywhere in the first 1024 bytes (some files carry junk before the header).
    public func sniff(_ prefix: Data) -> Bool {
        let bytes = [UInt8](prefix.prefix(1024))
        return PDFBytes.find(Array("%PDF-".utf8), in: bytes, from: 0, limit: Swift.max(bytes.count, 1)) != nil
    }

    // MARK: Metadata

    /// Title and author from the trailer `/Info` dictionary, falling back to XMP
    /// (`dc:title`, `dc:creator`) in the catalog `/Metadata` stream when Info is missing
    /// or blank. Also sets `pageCount` and `language` (catalog `/Lang`). Encrypted files
    /// return only what is readable without decryption (essentially the page count);
    /// only non-PDF data throws.
    public func readMetadata(from data: Data) throws -> ImportedMetadata {
        guard sniff(data) else { throw PDFError.notAPDF }
        let document = PDFDocument.parse(data)
        let pages = document.pages()
        var metadata = DocumentMetadata()
        if !pages.isEmpty { metadata.pageCount = pages.count }

        var title: String?
        var author: String?
        if !document.isEncrypted {
            if let info = document.dictionary(document.info) {
                title = Self.textString(info["Title"], in: document)
                author = Self.textString(info["Author"], in: document)
            }
            if title == nil || author == nil {
                if let xmp = Self.xmp(of: document) {
                    if title == nil { title = Self.xmpValue(xmp, element: "dc:title") }
                    if author == nil { author = Self.xmpValue(xmp, element: "dc:creator") }
                }
            }
            if let catalog = document.catalog,
               let language = Self.textString(catalog["Lang"], in: document) {
                metadata.language = language
            }
        }
        return ImportedMetadata(title: title, author: author, metadata: metadata)
    }

    /// A metadata string, decoded and trimmed; empty/whitespace values become nil.
    static func textString(_ object: PDFObject?, in document: PDFDocument) -> String? {
        guard case .string(let data)? = document.resolve(object) else { return nil }
        let text = PDFEncoding.decodeTextString(data)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The catalog XMP packet as text, when present and decodable.
    private static func xmp(of document: PDFDocument) -> String? {
        guard let catalog = document.catalog,
              let stream = document.stream(catalog["Metadata"]),
              let data = PDFFilters.decode(stream) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The first value of an XMP element: its text, or the first `rdf:li` inside it.
    static func xmpValue(_ xml: String, element: String) -> String? {
        guard let open = xml.range(of: "<\(element)") else { return nil }
        guard let openEnd = xml.range(of: ">", range: open.upperBound..<xml.endIndex) else { return nil }
        if xml[xml.index(before: openEnd.upperBound)] == "/" { return nil } // self-closing
        guard let close = xml.range(of: "</\(element)", range: openEnd.upperBound..<xml.endIndex) else { return nil }
        var inner = String(xml[openEnd.upperBound..<close.lowerBound])
        if let li = firstRDFLi(inner) { inner = li }
        let text = unescapeXML(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func firstRDFLi(_ inner: String) -> String? {
        guard let open = inner.range(of: "<rdf:li") else { return nil }
        guard let openEnd = inner.range(of: ">", range: open.upperBound..<inner.endIndex) else { return nil }
        guard let close = inner.range(of: "</rdf:li", range: openEnd.upperBound..<inner.endIndex) else { return nil }
        return String(inner[openEnd.upperBound..<close.lowerBound])
    }

    private static func unescapeXML(_ string: String) -> String {
        var out = string.replacingOccurrences(of: "&lt;", with: "<")
        out = out.replacingOccurrences(of: "&gt;", with: ">")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "&apos;", with: "'")
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        return out
    }

    // MARK: Text extraction

    /// One chunk per page with text (skipping empty pages), located by zero-based page
    /// index. Encrypted PDFs yield no chunks. Content streams are decoded and their text
    /// extracted with reasonable spacing and line breaks.
    public func extractText(from data: Data) throws -> [TextChunk] {
        guard sniff(data) else { throw PDFError.notAPDF }
        let document = PDFDocument.parse(data)
        guard !document.isEncrypted else { return [] }
        var extractor = PDFPageTextExtractor(document: document)
        var chunks: [TextChunk] = []
        for (index, page) in document.pages().enumerated() {
            extractor.beginPage()
            for stream in Self.contentStreams(page, in: document) {
                if let content = PDFFilters.decode(stream) {
                    extractor.run(stream: content, resources: page.resources, depth: 0)
                }
            }
            let text = Self.normalize(extractor.text)
            if !text.isEmpty {
                chunks.append(TextChunk(
                    locator: Locator(scheme: PDFLocators.pageScheme, value: String(index)),
                    label: "page \(index + 1)",
                    text: text))
            }
        }
        return chunks
    }

    /// The page's content streams in order (`/Contents` is a stream, a reference, or an
    /// array of them).
    static func contentStreams(_ page: PDFDocument.Page, in document: PDFDocument) -> [PDFStream] {
        guard let contents = document.resolve(page.dictionary["Contents"]) else { return [] }
        switch contents {
        case .stream(let stream):
            return [stream]
        case .array(let items):
            return items.prefix(1024).compactMap { document.stream($0) }
        default:
            return []
        }
    }

    /// Collapses runs of spaces, trims lines and drops empty ones.
    static func normalize(_ raw: String) -> String {
        raw.components(separatedBy: "\n")
            .map { line in line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
