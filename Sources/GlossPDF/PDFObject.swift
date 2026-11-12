import Foundation

// MARK: - Object model

/// One value in a PDF object graph. Streams keep their raw, undecoded bytes.
indirect enum PDFObject: Equatable, Sendable {
    case null
    case boolean(Bool)
    case integer(Int)
    case real(Double)
    /// A literal or hex string, undecoded bytes.
    case string(Data)
    /// A name without its leading slash (`/Type` → `"Type"`).
    case name(String)
    case array([PDFObject])
    case dictionary([String: PDFObject])
    /// `N G R`.
    case reference(Int, Int)
    case stream(PDFStream)
}

/// A stream object: its dictionary plus the bytes between `stream` and `endstream`.
struct PDFStream: Equatable, Sendable {
    var dictionary: [String: PDFObject]
    var raw: Data

    init(dictionary: [String: PDFObject], raw: Data) {
        self.dictionary = dictionary
        self.raw = raw
    }
}

// MARK: - Byte helpers

/// Byte-level helpers shared by the lexer, scanner and format.
enum PDFBytes {
    static func isWhitespace(_ c: UInt8) -> Bool { c == 0 || (c >= 9 && c <= 13) || c == 32 }

    /// PDF delimiters: `( ) < > [ ] { } / %`.
    static func isDelimiter(_ c: UInt8) -> Bool {
        switch c {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
        default: return false
        }
    }

    /// Any byte that is neither whitespace nor a delimiter.
    static func isRegular(_ c: UInt8) -> Bool { !isWhitespace(c) && !isDelimiter(c) }

    static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    /// Finds `needle` in `bytes` starting at `from`, looking at most `limit` bytes ahead.
    /// Linear scan; used only on short needles and bounded windows.
    static func find(_ needle: [UInt8], in bytes: [UInt8], from: Int, limit: Int) -> Int? {
        guard !needle.isEmpty, from >= 0, from < bytes.count, limit > 0 else { return nil }
        let end = min(bytes.count, from + limit)
        guard needle.count <= end - from else { return nil }
        let last = end - needle.count
        if from > last { return nil }
        let first = needle[0]
        var i = from
        while i <= last {
            if bytes[i] == first {
                var j = 1
                while j < needle.count, bytes[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}

// MARK: - Lexer

/// One lexical token of PDF syntax.
enum PDFToken: Equatable {
    case integer(Int)
    case real(Double)
    case name(String)
    case string(Data)
    /// A bare keyword: `obj`, `R`, `Tj`, `T*`, `d0`, …
    case keyword(String)
    case arrayOpen
    case arrayClose
    case dictOpen
    case dictClose
}

/// Whitespace- and comment-aware tokenizer over raw bytes. Malformed input yields skipped
/// bytes and partial tokens, never a trap; every call makes progress or hits end of input.
struct PDFLexer {
    /// Streams are capped at 4 MB per string token.
    private static let maxString = 4_000_000

    let bytes: [UInt8]
    /// Reading position; `bytes.count` means end of input.
    var index: Int
    /// Where the token returned by the last `nextToken()` call started.
    private(set) var tokenStart = 0

    init(_ bytes: [UInt8], at index: Int = 0) {
        self.bytes = bytes
        self.index = Swift.min(Swift.max(index, 0), bytes.count)
    }

    var isAtEnd: Bool { index >= bytes.count }

    /// Reads the next token, skipping whitespace and `%` comments; nil at end of input.
    mutating func nextToken() -> PDFToken? {
        while index < bytes.count {
            let c = bytes[index]
            if PDFBytes.isWhitespace(c) {
                index += 1
                continue
            }
            if c == 0x25 { // '%' comment runs to end of line
                index += 1
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
                continue
            }
            tokenStart = index
            switch c {
            case 0x28: // '('
                return .string(readLiteralString())
            case 0x3C: // '<' or '<<'
                if index + 1 < bytes.count, bytes[index + 1] == 0x3C {
                    index += 2
                    return .dictOpen
                }
                return .string(readHexString())
            case 0x3E: // '>' or '>>'
                if index + 1 < bytes.count, bytes[index + 1] == 0x3E {
                    index += 2
                    return .dictClose
                }
                index += 1 // stray '>' — skip
                continue
            case 0x5B: // '['
                index += 1
                return .arrayOpen
            case 0x5D: // ']'
                index += 1
                return .arrayClose
            case 0x2F: // '/'
                index += 1
                return readName()
            default:
                if let number = readNumber() { return number }
                return .keyword(readKeyword())
            }
        }
        return nil
    }

    /// Parses a PDF number: `[+-]?digits[.digits]`, also `.5`.
    private mutating func readNumber() -> PDFToken? {
        var i = index
        var negative = false
        if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D {
            negative = bytes[i] == 0x2D
            i += 1
        }
        var intPart = 0
        var digits = 0
        while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
            if intPart < 1_000_000_000 { intPart = intPart &* 10 &+ Int(bytes[i] - 0x30) }
            digits += 1
            i += 1
        }
        var fraction = 0.0
        var isReal = false
        if i < bytes.count, bytes[i] == 0x2E {
            isReal = true
            i += 1
            var scale = 0.1
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                if digits < 18 { fraction += Double(bytes[i] - 0x30) * scale }
                scale /= 10
                digits += 1
                i += 1
            }
        }
        guard digits > 0 || isReal else { return nil }
        index = i
        if isReal {
            var value = Double(intPart) + fraction
            if negative { value = -value }
            return .real(value)
        }
        var value = intPart
        if negative { value = -value }
        return .integer(value)
    }

    /// Parses `(…)` with `\` escapes, balanced parens and octal codes; EOLs become `\n`.
    private mutating func readLiteralString() -> Data {
        index += 1 // '('
        var out = [UInt8]()
        var depth = 1
        while index < bytes.count {
            let c = bytes[index]
            if c == 0x5C { // backslash escape
                index += 1
                guard index < bytes.count else { break }
                switch bytes[index] {
                case 0x6E: out.append(0x0A); index += 1 // n
                case 0x72: out.append(0x0D); index += 1 // r
                case 0x74: out.append(0x09); index += 1 // t
                case 0x0D: index += 1; if index < bytes.count, bytes[index] == 0x0A { index += 1 } // continuation
                case 0x0A: index += 1 // continuation
                case 0x28, 0x29, 0x5C: out.append(bytes[index]); index += 1 // ( ) \
                default:
                    var value = 0
                    var digits = 0
                    while digits < 3, index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x37 {
                        value = value &* 8 &+ Int(bytes[index] - 0x30)
                        digits += 1
                        index += 1
                    }
                    if digits > 0 {
                        out.append(UInt8(value & 0xFF))
                    } else { // unknown escape: keep the byte
                        out.append(bytes[index])
                        index += 1
                    }
                }
            } else if c == 0x28 {
                depth += 1
                out.append(c)
                index += 1
            } else if c == 0x29 {
                depth -= 1
                index += 1
                if depth == 0 { break }
                out.append(c)
            } else if c == 0x0D { // unescaped EOL → \n
                index += 1
                if index < bytes.count, bytes[index] == 0x0A { index += 1 }
                out.append(0x0A)
            } else {
                out.append(c)
                index += 1
            }
            if out.count > Self.maxString { break }
        }
        return Data(out)
    }

    /// Parses `<…>`: hex pairs, whitespace ignored, a dangling digit is padded with 0.
    private mutating func readHexString() -> Data {
        index += 1 // '<'
        var out = [UInt8]()
        var high: UInt8?
        while index < bytes.count {
            let c = bytes[index]
            if c == 0x3E { // '>'
                index += 1
                break
            }
            if let v = PDFBytes.hexValue(c) {
                if let h = high {
                    out.append((h << 4) | v)
                    high = nil
                } else {
                    high = v
                }
            }
            index += 1
        }
        if let h = high { out.append(h << 4) }
        if out.count > Self.maxString { out.removeSubrange(Self.maxString...) }
        return Data(out)
    }

    /// Parses `/Name` with `#xx` hex escapes.
    private mutating func readName() -> PDFToken {
        var out = [UInt8]()
        while index < bytes.count, out.count < 4096 {
            let c = bytes[index]
            if c == 0x23, index + 2 < bytes.count,
               let h = PDFBytes.hexValue(bytes[index + 1]), let l = PDFBytes.hexValue(bytes[index + 2]) {
                out.append((h << 4) | l)
                index += 3
            } else if PDFBytes.isRegular(c) {
                out.append(c)
                index += 1
            } else {
                break
            }
        }
        return .name(String(decoding: out, as: UTF8.self))
    }

    /// Reads a run of regular characters (operators, keywords), without allocating:
    /// short runs decode straight from the byte slice.
    private mutating func readKeyword() -> String {
        let start = index
        while index < bytes.count, PDFBytes.isRegular(bytes[index]), index - start < 64 {
            index += 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
}

// MARK: - Parser

/// Assembles tokens into `PDFObject` values. Tolerant: unterminated arrays and dictionaries
/// return what was collected so far.
enum PDFObjectParser {
    /// Parses one object at the lexer's position, or nil when no object starts there
    /// (the lexer is then left where it was).
    static func parse(_ lexer: inout PDFLexer) -> PDFObject? {
        let save = lexer.index
        guard let token = lexer.nextToken() else { return nil }
        switch token {
        case .integer(let n):
            // `n g R` — an indirect reference.
            let afterN = lexer.index
            if case .integer(let g)? = lexer.nextToken() {
                let afterG = lexer.index
                if case .keyword("R")? = lexer.nextToken() { return .reference(n, g) }
                lexer.index = afterG
            } else {
                lexer.index = afterN
            }
            return .integer(n)
        case .real(let value): return .real(value)
        case .name(let name): return .name(name)
        case .string(let data): return .string(data)
        case .arrayOpen: return .array(parseArray(&lexer))
        case .dictOpen: return .dictionary(parseDictionary(&lexer))
        case .keyword("true"): return .boolean(true)
        case .keyword("false"): return .boolean(false)
        case .keyword("null"): return .null
        default:
            lexer.index = save
            return nil
        }
    }

    /// Parses array elements until `]` (the opening `[` is already consumed).
    static func parseArray(_ lexer: inout PDFLexer) -> [PDFObject] {
        var items: [PDFObject] = []
        while items.count < 65_536 {
            let save = lexer.index
            guard let token = lexer.nextToken() else { break }
            if case .arrayClose = token { return items }
            lexer.index = save
            if let value = parse(&lexer) {
                items.append(value)
            } else {
                lexer.index = Swift.max(lexer.index, save + 1)
            }
        }
        return items
    }

    /// Parses `key value` pairs until `>>` (the opening `<<` is already consumed).
    static func parseDictionary(_ lexer: inout PDFLexer) -> [String: PDFObject] {
        var dict: [String: PDFObject] = [:]
        while dict.count < 65_536 {
            let save = lexer.index
            guard let token = lexer.nextToken() else { return dict } // unterminated
            switch token {
            case .dictClose:
                return dict
            case .name(let key):
                if let value = parse(&lexer) {
                    dict[key] = value
                } else {
                    lexer.index = Swift.max(lexer.index, save + 1)
                }
            default:
                lexer.index = Swift.max(lexer.index, save + 1)
            }
        }
        return dict
    }
}
