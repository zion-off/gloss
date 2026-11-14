/// The kind of a document ("epub", "pdf", later "article", "mobi", "comic"…).
///
/// An open struct rather than an enum: formats register their kind, and nothing in the core
/// switches over kinds.
public struct DocumentKind: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }

    public static let epub = DocumentKind("epub")
    public static let pdf = DocumentKind("pdf")
}
