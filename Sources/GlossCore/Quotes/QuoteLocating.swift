import Foundation

/// Formats whose passages can be pinned by quoting their extracted text, so links can be made
/// without a reader (`gloss link`). The locator a format makes is its own scheme, which only
/// its reader resolves (docs/DECISIONS.md D-160).
public protocol QuoteLocating: Sendable {
    /// What one text chunk of this format is called, as people say it: "section", "page".
    var partName: String { get }
    /// The 1-based number people would use for the part a chunk covers (spine position, page).
    func partNumber(of chunk: TextChunk) -> Int?
    /// A locator for a quote inside `chunk`; nil when the chunk isn't one of this format's.
    func quoteLocator(for anchor: QuoteAnchor, in chunk: TextChunk) -> Locator?
}

extension FormatRegistry {
    public func quoteLocator(for kind: DocumentKind) -> (any QuoteLocating)? {
        format(for: kind) as? any QuoteLocating
    }
}

/// An exact stretch of a book's extracted text: a text chunk's locator plus a UTF-16 range
/// into that chunk's text. Written `scheme:value@start-end` (`epub-section:5@1204-1251`), so a
/// script can list candidates once and link the one it chose.
public struct BookTextRef: Hashable, Sendable, CustomStringConvertible {
    public var chunk: Locator
    public var range: Range<Int>

    public init(chunk: Locator, range: Range<Int>) {
        self.chunk = chunk
        self.range = range
    }

    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard let at = trimmed.lastIndex(of: "@"), let colon = trimmed[..<at].firstIndex(of: ":"),
              let range = Self.range(String(trimmed[trimmed.index(after: at)...])) else { return nil }
        let scheme = trimmed[..<colon]
        let value = trimmed[trimmed.index(after: colon)..<at]
        guard !scheme.isEmpty, !value.isEmpty else { return nil }
        self.init(chunk: Locator(scheme: LocatorScheme(String(scheme)), value: String(value)), range: range)
    }

    public var description: String { "\(chunk.scheme.rawValue):\(chunk.value)@\(range.lowerBound)-\(range.upperBound)" }

    /// `start-end`, 0-based, end exclusive, start < end.
    public static func range(_ text: String) -> Range<Int>? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]), start >= 0, end > start else { return nil }
        return start..<end
    }
}
