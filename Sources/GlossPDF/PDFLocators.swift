import Foundation
import GlossCore

/// Locator schemes for PDF documents. Search chunks use the page scheme; passages use
/// the passage scheme with `PDFPassageLocator` JSON as the value. The locators are pure
/// `Codable` so the Mac PDFKit reader can create them and everything else can store,
/// sort and display them without PDFKit.
public enum PDFLocators {
    /// One page of a PDF; the value is the zero-based page index. Used by text chunks.
    public static let pageScheme = LocatorScheme("pdf-page")
    /// A passage inside a PDF; the value is compact `PDFPassageLocator` JSON. Used by
    /// highlights and note links.
    public static let passageScheme = LocatorScheme("pdf")
    /// A passage pinned by its words (`gloss link`): `PDFQuoteLocator` JSON, resolved by
    /// the PDFKit reader against the page's text.
    public static let quoteScheme = LocatorScheme("pdf-quote")
}

/// A passage the CLI pinned by quoting a page's extracted text: the page plus the quote, its
/// context and occurrence. The PDFKit reader finds the words in `PDFPage.string` and turns them
/// into a `PDFPassageLocator` when it draws or jumps.
public struct PDFQuoteLocator: Codable, Hashable, Sendable {
    public var v: Int = 1
    /// Zero-based page index.
    public var page: Int
    public var quote: QuoteAnchor

    public init(page: Int, quote: QuoteAnchor) {
        self.page = page
        self.quote = quote
    }

    /// The opaque locator: compact JSON with sorted keys, so the same quote makes the same
    /// locator and reuses its link target.
    public var locator: Locator {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let value = (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Locator(scheme: PDFLocators.quoteScheme, value: value)
    }

    public init?(locator: Locator) {
        guard locator.scheme == PDFLocators.quoteScheme,
              let decoded = try? JSONDecoder().decode(PDFQuoteLocator.self, from: Data(locator.value.utf8)),
              decoded.page >= 0 else { return nil }
        self = decoded
    }
}

/// Where a highlighted passage sits: page(s) plus UTF-16 ranges into PDFKit's
/// `PDFPage.string` and rectangles in PDF page space (points, bottom-left origin).
public struct PDFPassageLocator: Codable, Hashable, Sendable {
    /// One page's worth of a passage.
    public struct PageSpan: Codable, Hashable, Sendable {
        /// Zero-based page index.
        public var page: Int
        /// `[location, length]` pairs, UTF-16 offsets into PDFKit's `PDFPage.string`.
        public var ranges: [[Int]]
        /// `[x, y, width, height]` in PDF page space (points, bottom-left origin).
        public var rects: [[Double]]

        public init(page: Int, ranges: [[Int]], rects: [[Double]]) {
            self.page = page
            self.ranges = ranges
            self.rects = rects
        }
    }

    /// Version of the locator shape, for future changes.
    public var v: Int = 1
    public var pages: [PageSpan]

    public init(pages: [PageSpan]) {
        self.pages = pages
    }

    /// The opaque locator: scheme "pdf", value = compact JSON with sorted keys.
    public var locator: Locator {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let value = (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Locator(scheme: PDFLocators.passageScheme, value: value)
    }

    /// Parses a passage locator; nil for other schemes or bad JSON.
    public init?(locator: Locator) {
        guard locator.scheme == PDFLocators.passageScheme,
              let decoded = try? JSONDecoder().decode(PDFPassageLocator.self, from: Data(locator.value.utf8))
        else { return nil }
        v = decoded.v
        pages = decoded.pages
    }

    /// "page 3" or "pages 3–4" (1-based, en dash); empty when there are no spans.
    public var label: String {
        guard let first = pages.first?.page else { return "" }
        let last = pages.last?.page ?? first
        return first == last ? "page \(first + 1)" : "pages \(first + 1)–\(last + 1)"
    }

    /// The zero-based index of the first page the passage sits on.
    public var firstPage: Int { pages.first?.page ?? 0 }
}
