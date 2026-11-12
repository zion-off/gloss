import Foundation

/// A `gloss://` link. These appear as ordinary markdown link destinations in notes, and work
/// from other apps, scripts and `gloss open`.
///
///     gloss://passage/<linkTargetID>   a passage in a book
///     gloss://page/<pageID>            a notes page
///     gloss://book/<documentID>        a book, at its last position
public enum GlossLink: Hashable, Sendable {
    case passage(LinkTargetID)
    case page(PageID)
    case document(DocumentID)

    public static let scheme = "gloss"

    public init?(_ url: URL) {
        self.init(string: url.absoluteString)
    }

    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let prefix = "\(Self.scheme)://"
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        var rest = Substring(trimmed.dropFirst(prefix.count))
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<cut] }
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let id = GlossID(string: parts[1]) else { return nil }
        switch parts[0].lowercased() {
        case "passage": self = .passage(LinkTargetID(id))
        case "page": self = .page(PageID(id))
        case "book": self = .document(DocumentID(id))
        default: return nil
        }
    }

    public var string: String {
        switch self {
        case .passage(let id): "\(Self.scheme)://passage/\(id)"
        case .page(let id): "\(Self.scheme)://page/\(id)"
        case .document(let id): "\(Self.scheme)://book/\(id)"
        }
    }

    public var url: URL { URL(string: string)! }

    public var referenceTarget: ReferenceTarget {
        switch self {
        case .passage(let id): .passage(id)
        case .page(let id): .page(id)
        case .document(let id): .document(id)
        }
    }
}

extension GlossLink: CustomStringConvertible {
    public var description: String { string }
}
