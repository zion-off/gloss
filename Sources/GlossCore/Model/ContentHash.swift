import Crypto
import Foundation

/// The SHA-256 of a file's bytes, lowercase hex. Files are stored content-addressed and never
/// change, which is what keeps passage locators valid forever.
public struct ContentHash: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let hex: String

    public init?(hex: String) {
        let lower = hex.lowercased()
        guard lower.count == 64, lower.allSatisfy({ $0.isHexDigit }) else { return nil }
        self.hex = lower
    }

    public static func of(_ data: Data) -> ContentHash {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { byte in
            let s = String(byte, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
        return ContentHash(uncheckedHex: hex)
    }

    private init(uncheckedHex: String) { self.hex = uncheckedHex }

    public var description: String { hex }
    public var short: String { String(hex.prefix(12)) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = ContentHash(hex: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad content hash")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public static func < (lhs: ContentHash, rhs: ContentHash) -> Bool { lhs.hex < rhs.hex }
}
