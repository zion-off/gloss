import Foundation

/// The family of a locator, which names the engine that can interpret it.
public struct LocatorScheme: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// An opaque position or range inside a document. Only the engine that created it knows what
/// `value` means (an EPUB CFI, a PDF page + ranges, …).
public struct Locator: Hashable, Codable, Sendable {
    public var scheme: LocatorScheme
    public var value: String

    public init(scheme: LocatorScheme, value: String) {
        self.scheme = scheme
        self.value = value
    }
}

/// A selected stretch of a document: where it is, plus what it said and where it was, captured
/// at creation so nothing downstream needs an engine.
public struct Passage: Hashable, Codable, Sendable {
    public var locator: Locator
    /// The selected text, whitespace-normalised.
    public var quote: String
    /// Human location, e.g. "chapter 3" or "page 12".
    public var label: String?
    /// 0…1 position in the document, used for ordering.
    public var progression: Double?

    public init(locator: Locator, quote: String, label: String? = nil, progression: Double? = nil) {
        self.locator = locator
        self.quote = Passage.normalize(quote)
        self.label = label
        self.progression = progression
    }

    /// Collapses runs of whitespace (including newlines) into single spaces and trims.
    public static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
