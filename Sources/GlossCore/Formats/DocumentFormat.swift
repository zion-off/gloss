import Foundation

/// A library filter group ("books", "pdfs"). Each format says which shelf it belongs on, so a
/// new format (comics, say) brings its own filter without editing the library.
public struct LibraryShelf: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let books = LibraryShelf("books")
    public static let pdfs = LibraryShelf("pdfs")
}

/// What a format reads from a file at import.
public struct ImportedMetadata: Hashable, Sendable {
    public var title: String?
    public var author: String?
    public var metadata: DocumentMetadata

    public init(title: String? = nil, author: String? = nil, metadata: DocumentMetadata = DocumentMetadata()) {
        self.title = title
        self.author = author
        self.metadata = metadata
    }
}

/// A searchable stretch of a document's text with a locator its engine can jump to.
public struct TextChunk: Hashable, Sendable {
    public var locator: Locator
    public var label: String?
    public var text: String

    public init(locator: Locator, label: String?, text: String) {
        self.locator = locator
        self.label = label
        self.text = text
    }
}

/// Everything that varies by document kind on the import side. Optional capabilities are
/// separate protocols (`TextExtracting`, `CoverExtracting`).
public protocol DocumentFormat: Sendable {
    var kind: DocumentKind { get }
    /// The badge on covers ("epub", "pdf").
    var badge: String { get }
    var shelf: LibraryShelf { get }
    /// The SF Symbol name for its shelf in the app's source list ("book", "doc.richtext"); plain
    /// data, so the core stays UI-free. Defaults to "doc".
    var shelfSymbol: String { get }
    /// Lowercase extensions without the dot.
    var fileExtensions: [String] { get }
    /// True if the first bytes of a file look like this format.
    func sniff(_ prefix: Data) -> Bool
    func readMetadata(from data: Data) throws -> ImportedMetadata
}

extension DocumentFormat {
    public var shelfSymbol: String { "doc" }
}

/// Formats whose text can be extracted for search.
public protocol TextExtracting: Sendable {
    func extractText(from data: Data) throws -> [TextChunk]
}

/// Anything that can produce a cover image for a file (the format itself, or a renderer the
/// app registers, such as PDFKit's first page).
public protocol CoverExtracting: Sendable {
    func extractCover(from data: Data) throws -> CoverImage?
}

/// The registered formats. Composition roots build one; nothing else knows the list.
public struct FormatRegistry: Sendable {
    public let formats: [any DocumentFormat]
    private let extraCoverExtractors: [DocumentKind: [any CoverExtracting]]

    public init(_ formats: [any DocumentFormat], extraCoverExtractors: [DocumentKind: [any CoverExtracting]] = [:]) {
        self.formats = formats
        self.extraCoverExtractors = extraCoverExtractors
    }

    public func format(for kind: DocumentKind) -> (any DocumentFormat)? {
        formats.first { $0.kind == kind }
    }

    /// Detects by content first, then by file extension.
    public func detect(prefix: Data, filename: String?) -> (any DocumentFormat)? {
        if let byContent = formats.first(where: { $0.sniff(prefix) }) { return byContent }
        guard let ext = filename.map({ ($0 as NSString).pathExtension.lowercased() }), !ext.isEmpty else { return nil }
        return formats.first { $0.fileExtensions.contains(ext) }
    }

    public var supportedExtensions: [String] { formats.flatMap(\.fileExtensions) }

    /// Shelves in registration order, without duplicates.
    public var shelves: [LibraryShelf] {
        formats.reduce(into: []) { result, format in if !result.contains(format.shelf) { result.append(format.shelf) } }
    }

    public func shelf(of kind: DocumentKind) -> LibraryShelf? { format(for: kind)?.shelf }
    /// The symbol of a shelf: its first format's.
    public func symbol(of shelf: LibraryShelf) -> String {
        formats.first { $0.shelf == shelf }?.shelfSymbol ?? "doc"
    }
    /// The symbol of a document of this kind: its own format's ("doc" for a kind nobody reads).
    public func symbol(of kind: DocumentKind) -> String { format(for: kind)?.shelfSymbol ?? "doc" }
    public func badge(of kind: DocumentKind) -> String { format(for: kind)?.badge ?? kind.rawValue }

    public func textExtractor(for kind: DocumentKind) -> (any TextExtracting)? {
        format(for: kind) as? any TextExtracting
    }

    /// The format's own extractor first, then any registered extras.
    public func coverExtractors(for kind: DocumentKind) -> [any CoverExtracting] {
        let own = (format(for: kind) as? any CoverExtracting).map { [$0] } ?? []
        return own + (extraCoverExtractors[kind] ?? [])
    }

    /// A copy with additional cover extractors (the Mac app adds a PDFKit renderer).
    public func adding(coverExtractor: any CoverExtracting, for kind: DocumentKind) -> FormatRegistry {
        var extras = extraCoverExtractors
        extras[kind, default: []].append(coverExtractor)
        return FormatRegistry(formats, extraCoverExtractors: extras)
    }
}
