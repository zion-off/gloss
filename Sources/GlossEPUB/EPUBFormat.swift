import Foundation
import GlossArchive
import GlossCore

/// Locator schemes owned by the EPUB engine.
public enum EPUBLocators {
    /// Passages and reading positions: foliate-js CFIs (`epubcfi(…)`).
    public static let cfiScheme = LocatorScheme("epubcfi")
    /// Search chunks extracted on import: the spine index of a section.
    public static let sectionScheme = LocatorScheme("epub-section")
    /// Table-of-contents targets: an href inside the book.
    public static let hrefScheme = LocatorScheme("epub-href")
    /// Passages pinned by their words (`gloss link`, D-190): `EPUBQuoteLocator` JSON, resolved by
    /// the reader against the section it loads.
    public static let quoteScheme = LocatorScheme("epub-quote")
}

/// A passage the CLI pinned by quoting a section's text: the spine index plus the quote, its
/// context and occurrence. The reader finds the words in the section and draws them like a CFI.
public struct EPUBQuoteLocator: Codable, Hashable, Sendable {
    public var v: Int = 1
    /// Spine index (0-based).
    public var section: Int
    public var quote: QuoteAnchor

    public init(section: Int, quote: QuoteAnchor) {
        self.section = section
        self.quote = quote
    }

    /// The opaque locator: compact JSON with sorted keys, so the same quote makes the same
    /// locator and reuses its link target.
    public var locator: Locator {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let value = (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Locator(scheme: EPUBLocators.quoteScheme, value: value)
    }

    public init?(locator: Locator) {
        guard locator.scheme == EPUBLocators.quoteScheme,
              let decoded = try? JSONDecoder().decode(EPUBQuoteLocator.self, from: Data(locator.value.utf8)),
              decoded.section >= 0 else { return nil }
        self = decoded
    }
}

/// EPUB 2 and 3 on the import side: metadata, per-section text and the cover.
public struct EPUBFormat: DocumentFormat, TextExtracting, CoverExtracting, QuoteLocating {
    public init() {}

    public var kind: DocumentKind { .epub }
    public var badge: String { "epub" }
    public var shelf: LibraryShelf { .books }
    public var shelfSymbol: String { "book" }
    public var fileExtensions: [String] { ["epub"] }

    /// A ZIP whose first entry is the `mimetype` file, as the spec requires; or any ZIP with a
    /// container.xml (checked at import by `readMetadata`).
    public func sniff(_ prefix: Data) -> Bool {
        guard prefix.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { return false }
        return String(decoding: prefix.prefix(200), as: UTF8.self).contains("application/epub+zip")
    }

    public func readMetadata(from data: Data) throws -> ImportedMetadata {
        let package = try EPUBPackage(data: data)
        let metadata = DocumentMetadata(language: package.language, publisher: package.publisher, identifier: package.identifier,
                                        published: package.date, pageCount: nil)
        return ImportedMetadata(title: package.title, author: package.authors.isEmpty ? nil : package.authors.joined(separator: ", "),
                                metadata: metadata)
    }

    public func extractText(from data: Data) throws -> [TextChunk] {
        let package = try EPUBPackage(data: data)
        return package.spine.enumerated().compactMap { index, item in
            guard item.mediaType.contains("html") || item.path.hasSuffix("html") || item.path.hasSuffix("htm"),
                  let raw = try? package.data(of: item) else { return nil }
            let text = HTMLText.extract(String(decoding: raw, as: UTF8.self))
            guard !text.isEmpty else { return nil }
            return TextChunk(locator: Locator(scheme: EPUBLocators.sectionScheme, value: String(index)),
                             label: package.label(forSpineIndex: index) ?? "section \(index + 1)", text: text)
        }
    }

    // MARK: QuoteLocating

    public var partName: String { "section" }

    /// The spine position, 1-based (text chunks carry the 0-based spine index).
    public func partNumber(of chunk: TextChunk) -> Int? {
        chunk.locator.scheme == EPUBLocators.sectionScheme ? Int(chunk.locator.value).map { $0 + 1 } : nil
    }

    public func quoteLocator(for anchor: QuoteAnchor, in chunk: TextChunk) -> Locator? {
        guard chunk.locator.scheme == EPUBLocators.sectionScheme, let section = Int(chunk.locator.value), section >= 0 else { return nil }
        return EPUBQuoteLocator(section: section, quote: anchor).locator
    }

    public func extractCover(from data: Data) throws -> CoverImage? {
        let package = try EPUBPackage(data: data)
        guard let item = package.coverItem, let bytes = try? package.data(of: item), !bytes.isEmpty else { return nil }
        let sniffed = CoverImage.sniffMimeType(bytes)
        return CoverImage(data: bytes, mimeType: sniffed == "application/octet-stream" ? item.mediaType : sniffed)
    }
}
