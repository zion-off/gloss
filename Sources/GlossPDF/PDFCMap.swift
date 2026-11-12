import Foundation

/// A parsed ToUnicode CMap: character codes → Unicode strings, plus the code byte length
/// from `codespacerange`. Covers `bfchar`, `bfrange` (including the array form) and
/// 1–4 byte codes.
struct PDFCMap: Sendable {
    /// Bounds against absurd CMaps.
    private static let maxEntries = 65_536
    private static let maxRangeSpan: UInt32 = 65_535

    /// Bytes per character code (from `codespacerange`), 1–4.
    var codeLength = 2
    /// Code → Unicode. Empty means "no usable mapping".
    var map: [UInt32: String] = [:]

    /// Parses a CMap, ignoring everything outside the three section kinds it needs.
    static func parse(_ data: Data) -> PDFCMap {
        var cmap = PDFCMap()
        var lexer = PDFLexer([UInt8](data))
        while cmap.map.count < maxEntries, let token = lexer.nextToken() {
            guard case .keyword(let keyword) = token else { continue }
            switch keyword {
            case "begincodespacerange": cmap.readCodeSpace(&lexer)
            case "beginbfchar": cmap.readBFChar(&lexer)
            case "beginbfrange": cmap.readBFRange(&lexer)
            default: break
            }
        }
        return cmap
    }

    /// `begincodespacerange <lo> <hi> … endcodespacerange` — takes the code byte length.
    private mutating func readCodeSpace(_ lexer: inout PDFLexer) {
        while let token = lexer.nextToken() {
            switch token {
            case .keyword("endcodespacerange"):
                return
            case .string(let low):
                guard case .string? = lexer.nextToken() else { continue }
                if low.count >= 1, low.count <= 4 { codeLength = low.count }
            default:
                break
            }
        }
    }

    /// `beginbfchar <code> <unicode> … endbfchar`.
    private mutating func readBFChar(_ lexer: inout PDFLexer) {
        while map.count < Self.maxEntries, let token = lexer.nextToken() {
            switch token {
            case .keyword("endbfchar"):
                return
            case .string(let code):
                guard case .string(let destination)? = lexer.nextToken() else { continue }
                if let key = Self.code(code) { map[key] = Self.utf16String(destination) }
            default:
                break
            }
        }
    }

    /// `beginbfrange <lo> <hi> <dst|[]> … endbfrange`.
    private mutating func readBFRange(_ lexer: inout PDFLexer) {
        while map.count < Self.maxEntries, let token = lexer.nextToken() {
            switch token {
            case .keyword("endbfrange"):
                return
            case .string(let lowData):
                guard case .string(let highData)? = lexer.nextToken() else { continue }
                guard let low = Self.code(lowData), let high = Self.code(highData),
                      high >= low, low.distance(to: high) <= Int(Self.maxRangeSpan) else { continue }
                let span = high - low
                let save = lexer.index
                guard let third = lexer.nextToken() else { continue }
                switch third {
                case .string(let destination):
                    let units = PDFEncoding.utf16Units([UInt8](destination))
                    if units.count == 1, let base = UnicodeScalar(units[0]) {
                        // Single UTF-16 code unit: each code gets base + offset.
                        for offset in 0...span {
                            if let scalar = UnicodeScalar(UInt32(base) + UInt32(offset)) {
                                map[low + UInt32(offset)] = String(Character(scalar))
                            }
                        }
                    } else if units.count == 2, let base = Self.scalar(units) {
                        // Surrogate pair: the code point increments across the pair.
                        for offset in 0...span {
                            if let scalar = UnicodeScalar(base + UInt32(offset)) {
                                map[low + UInt32(offset)] = String(Character(scalar))
                            }
                        }
                    } else if span == 0 {
                        map[low] = Self.utf16String(destination)
                    }
                case .arrayOpen:
                    // Array form: one destination per code.
                    var index: UInt32 = 0
                    while index <= span, map.count < Self.maxEntries, let element = lexer.nextToken() {
                        if case .arrayClose = element { break }
                        if case .string(let destination) = element {
                            map[low + index] = Self.utf16String(destination)
                            index += 1
                        }
                    }
                default:
                    lexer.index = save
                }
            default:
                break
            }
        }
    }

    /// A big-endian code of at most 4 bytes.
    static func code(_ data: Data) -> UInt32? {
        guard !data.isEmpty, data.count <= 4 else { return nil }
        var value: UInt32 = 0
        for byte in data { value = (value << 8) | UInt32(byte) }
        return value
    }

    /// The code point of a surrogate pair, if valid.
    static func scalar(_ units: [UInt16]) -> UInt32? {
        guard units.count == 2,
              units[0] >= 0xD800, units[0] <= 0xDBFF,
              units[1] >= 0xDC00, units[1] <= 0xDFFF else { return nil }
        return 0x10000 + (UInt32(units[0]) - 0xD800) * 0x400 + (UInt32(units[1]) - 0xDC00)
    }

    /// Big-endian UTF-16 bytes → string.
    static func utf16String(_ data: Data) -> String {
        String(decoding: PDFEncoding.utf16Units([UInt8](data)), as: UTF16.self)
    }
}
