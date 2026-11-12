import Foundation

/// A typed identifier: `Identifier<Page>` and `Identifier<Document>` cannot be mixed up.
public struct Identifier<Entity>: Hashable, Comparable, Sendable {
    public let raw: GlossID

    public init(_ raw: GlossID) { self.raw = raw }

    public init?(_ string: some StringProtocol) {
        guard let raw = GlossID(string: string) else { return nil }
        self.raw = raw
    }

    public var stringValue: String { raw.stringValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }
}

extension Identifier: CustomStringConvertible {
    public var description: String { raw.stringValue }
}

extension Identifier: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let raw = GlossID(string: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a gloss id: \(string)")
        }
        self.raw = raw
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw.stringValue)
    }
}

public typealias DocumentID = Identifier<Document>
public typealias PageID = Identifier<Page>
public typealias HighlightID = Identifier<Highlight>
public typealias LinkTargetID = Identifier<LinkTarget>
public typealias TrashEntryID = Identifier<TrashEntry>
