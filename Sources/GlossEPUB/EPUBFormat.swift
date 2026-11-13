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
}

/// EPUB 2 and 3 on the import side: metadata, per-section text and the cover.
public struct EPUBFormat: DocumentFormat, TextExtracting, CoverExtracting {
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

    public func extractCover(from data: Data) throws -> CoverImage? {
        let package = try EPUBPackage(data: data)
        guard let item = package.coverItem, let bytes = try? package.data(of: item), !bytes.isEmpty else { return nil }
        let sniffed = CoverImage.sniffMimeType(bytes)
        return CoverImage(data: bytes, mimeType: sniffed == "application/octet-stream" ? item.mediaType : sniffed)
    }
}
