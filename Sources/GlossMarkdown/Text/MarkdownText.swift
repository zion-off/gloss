/// A markdown string indexed by UTF-16 offsets, the unit `NSRange` and the editor use.
/// Every range produced by this module is a `Range<Int>` of UTF-16 code units.
public struct MarkdownText: Sendable {
    public let string: String
    public let units: [UInt16]
    /// Line ranges, excluding the line terminator.
    public let lines: [Range<Int>]

    public init(_ string: String) {
        self.string = string
        self.units = Array(string.utf16)
        var lines: [Range<Int>] = []
        var start = 0
        for (index, unit) in units.enumerated() where unit == 0x0A {
            var end = index
            if end > start, units[end - 1] == 0x0D { end -= 1 }
            lines.append(start..<end)
            start = index + 1
        }
        var end = units.count
        if end > start, units[end - 1] == 0x0D { end -= 1 }
        lines.append(start..<end)
        self.lines = lines
    }

    public var length: Int { units.count }

    public subscript(range: Range<Int>) -> String {
        String(decoding: units[range.clamped(to: 0..<units.count)], as: UTF16.self)
    }

    public func unit(at index: Int) -> UInt16? {
        index >= 0 && index < units.count ? units[index] : nil
    }

    /// Index of the line containing `offset` (offsets at a line end belong to that line).
    public func lineIndex(containing offset: Int) -> Int {
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].lowerBound <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Indices of every line touched by `range`.
    public func lineIndices(touching range: Range<Int>) -> ClosedRange<Int> {
        let first = lineIndex(containing: range.lowerBound)
        let last = lineIndex(containing: max(range.lowerBound, range.upperBound - (range.isEmpty ? 0 : 1)))
        return first...max(first, last)
    }

    /// The Unicode scalar starting at `index`, or ending just before it (`before: true`).
    public func scalar(at index: Int, before: Bool = false) -> Unicode.Scalar? {
        if before {
            guard let unit = unit(at: index - 1) else { return nil }
            if UTF16.isTrailSurrogate(unit), let lead = self.unit(at: index - 2), UTF16.isLeadSurrogate(lead) {
                return UTF16.decode(UTF16.EncodedScalar([lead, unit]))
            }
            return Unicode.Scalar(unit)
        }
        guard let unit = unit(at: index) else { return nil }
        if UTF16.isLeadSurrogate(unit), let trail = self.unit(at: index + 1), UTF16.isTrailSurrogate(trail) {
            return UTF16.decode(UTF16.EncodedScalar([unit, trail]))
        }
        return Unicode.Scalar(unit)
    }

    /// Offset of the first non-space/tab unit in `range`, or `range.upperBound`.
    public func firstNonBlank(in range: Range<Int>) -> Int {
        var index = range.lowerBound
        while index < range.upperBound, units[index] == 0x20 || units[index] == 0x09 { index += 1 }
        return index
    }

    public func isBlank(_ range: Range<Int>) -> Bool { firstNonBlank(in: range) == range.upperBound }
}

extension UInt16 {
    static let space: UInt16 = 0x20, tab: UInt16 = 0x09, hash: UInt16 = 0x23, star: UInt16 = 0x2A
    static let underscore: UInt16 = 0x5F, tilde: UInt16 = 0x7E, backtick: UInt16 = 0x60, gt: UInt16 = 0x3E
    static let lt: UInt16 = 0x3C, dash: UInt16 = 0x2D, plus: UInt16 = 0x2B, dot: UInt16 = 0x2E
    static let rparen: UInt16 = 0x29, lparen: UInt16 = 0x28, lbracket: UInt16 = 0x5B, rbracket: UInt16 = 0x5D
    static let backslash: UInt16 = 0x5C, bang: UInt16 = 0x21, quote: UInt16 = 0x22, apostrophe: UInt16 = 0x27
    static let x: UInt16 = 0x78, X: UInt16 = 0x58, newline: UInt16 = 0x0A

    var isDigit: Bool { self >= 0x30 && self <= 0x39 }
    var isSpaceOrTab: Bool { self == .space || self == .tab }
    var isASCIIPunctuation: Bool {
        (0x21...0x2F).contains(self) || (0x3A...0x40).contains(self) || (0x5B...0x60).contains(self) || (0x7B...0x7E).contains(self)
    }
}
