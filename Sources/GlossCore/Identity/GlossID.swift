import Foundation

/// A 128-bit identifier, written as 26 lowercase Crockford base32 characters.
///
/// Generated as UUIDv7 (48-bit millisecond timestamp, version and variant bits, random tail),
/// so IDs are unique across devices and roughly time-ordered.
public struct GlossID: Hashable, Comparable, Sendable {
    public let high: UInt64
    public let low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz".utf8)
    /// 256-entry lookup; 0xFF marks bytes that are not base32 digits.
    static let decodeTable: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (index, char) in alphabet.enumerated() {
            table[Int(char)] = UInt8(index)
            if char >= UInt8(ascii: "a") { table[Int(char - 32)] = UInt8(index) }
        }
        let aliases: [(Unicode.Scalar, UInt8)] = [("o", 0), ("O", 0), ("i", 1), ("I", 1), ("l", 1), ("L", 1)]
        for (alias, value) in aliases { table[Int(UInt8(ascii: alias))] = value }
        return table
    }()

    /// The canonical 26-character form.
    public var stringValue: String {
        var chars = [UInt8](repeating: 0, count: 26)
        var hi = high, lo = low
        // 26 chars * 5 bits = 130 bits; emit from the least significant end.
        for index in stride(from: 25, through: 0, by: -1) {
            chars[index] = Self.alphabet[Int(lo & 0x1f)]
            lo = (lo >> 5) | ((hi & 0x1f) << 59)
            hi >>= 5
        }
        return String(decoding: chars, as: UTF8.self)
    }

    /// Parses the 26-character form (case-insensitive, Crockford aliases accepted).
    public init?(string: some StringProtocol) {
        let bytes = Array(string.utf8)
        guard bytes.count == 26 else { return nil }
        var hi: UInt64 = 0, lo: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            let value = Self.decodeTable[Int(byte)]
            guard value != 0xFF else { return nil }
            // The first character carries only the top 3 bits (130 - 128 = 2 spare bits).
            if index == 0 && value > 7 { return nil }
            hi = (hi << 5) | (lo >> 59)
            lo = (lo << 5) | UInt64(value)
        }
        self.init(high: hi, low: lo)
    }

    public static func < (lhs: GlossID, rhs: GlossID) -> Bool {
        (lhs.high, lhs.low) < (rhs.high, rhs.low)
    }

    /// Builds a UUIDv7 from a millisecond timestamp and 74 random bits.
    public static func uuidV7(milliseconds: UInt64, random: (UInt64, UInt64)) -> GlossID {
        let time = milliseconds & 0xFFFF_FFFF_FFFF
        let randA = random.0 & 0xFFF
        let high = (time << 16) | (0x7 << 12) | randA
        let low = (0b10 << 62) | (random.1 & 0x3FFF_FFFF_FFFF_FFFF)
        return GlossID(high: high, low: low)
    }

    /// The embedded UUIDv7 timestamp, if this is a v7 ID.
    public var timestamp: Date? {
        guard (high >> 12) & 0xF == 0x7 else { return nil }
        return Date(timeIntervalSince1970: Double(high >> 16) / 1000)
    }
}

extension GlossID: CustomStringConvertible {
    public var description: String { stringValue }
}
