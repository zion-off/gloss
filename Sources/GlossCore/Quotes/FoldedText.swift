import Foundation

/// Text folded for quote matching, with a map from every folded unit back to the UTF-16 range
/// of the source it came from (docs/DECISIONS.md D-190).
///
/// Folding works scalar by scalar, so it is the same on every platform and in the reader's
/// TypeScript twin (`web/src/bridge/quote.ts`), which must stay in step with it:
///
/// - Unicode `White_Space` is dropped (`.stripped`) or a run of it becomes one space
///   (`.collapsed`, leading and trailing runs dropped);
/// - soft hyphens and zero-width characters are dropped;
/// - curly quotes fold to `'` and `"`, dashes and the minus sign to `-`;
/// - everything else is decomposed (NFKD: ligatures split, accents separate) and, when
///   ignoring case, lowercased.
public struct FoldedText: Sendable {
    public enum Whitespace: Sendable {
        /// A run of whitespace is one space: the quote's spaces must meet spaces in the text.
        case collapsed
        /// Whitespace is ignored: "a b" matches "ab". Tolerates the extractor and the reader's
        /// DOM disagreeing about spaces between blocks.
        case stripped
    }

    /// The folded text, as UTF-16 units.
    public let units: [UInt16]
    /// For every unit, the UTF-16 range of the source scalar (or whitespace run) it came from.
    public let sourceRanges: [Range<Int>]

    public init(_ text: String, whitespace: Whitespace, ignoringCase: Bool = false) {
        var units: [UInt16] = []
        var ranges: [Range<Int>] = []
        units.reserveCapacity(text.utf16.count)
        ranges.reserveCapacity(text.utf16.count)
        var offset = 0
        var pendingSpace: Range<Int>?
        var cache: [UInt32: [UInt16]] = [:]
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            defer { offset += width }
            if scalar.properties.isWhitespace {
                if whitespace == .collapsed {
                    pendingSpace = (pendingSpace?.lowerBound ?? offset)..<(offset + width)
                }
                continue
            }
            let folded: [UInt16]
            if scalar.value < 0x80 {
                folded = Self.fold(scalar, ignoringCase: ignoringCase)
            } else if let cached = cache[scalar.value] {
                folded = cached
            } else {
                folded = Self.fold(scalar, ignoringCase: ignoringCase)
                cache[scalar.value] = folded
            }
            guard !folded.isEmpty else { continue }
            if let space = pendingSpace {
                if !units.isEmpty {
                    units.append(0x20)
                    ranges.append(space)
                }
                pendingSpace = nil
            }
            for unit in folded {
                units.append(unit)
                ranges.append(offset..<(offset + width))
            }
        }
        self.units = units
        self.sourceRanges = ranges
    }

    public var isEmpty: Bool { units.isEmpty }
    public var count: Int { units.count }

    /// Folded start offsets of every occurrence of `needle` (overlapping ones included), in order.
    public func occurrences(of needle: [UInt16], in window: Range<Int>? = nil) -> [Int] {
        let bounds = window ?? 0..<units.count
        guard let first = needle.first, needle.count <= bounds.count else { return [] }
        var starts: [Int] = []
        var index = bounds.lowerBound
        let last = bounds.upperBound - needle.count
        while index <= last {
            if units[index] == first {
                var matched = true
                var k = 1
                while k < needle.count {
                    if units[index + k] != needle[k] { matched = false; break }
                    k += 1
                }
                if matched { starts.append(index) }
            }
            index += 1
        }
        return starts
    }

    /// Whether a folded range starts and ends at word edges: a match that begins or ends with a
    /// letter or digit may not continue a word ("the" is not in "mother"). Scripts written without
    /// spaces between words (Chinese, Japanese, Thai...) have no word edges to check, so every
    /// position next to them is an edge.
    public func isWholeWords(_ range: Range<Int>) -> Bool {
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < units.count, let scalar = Unicode.Scalar(units[index]) else { return false }
            if Self.isSpaceless(scalar) { return false }
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                || scalar.properties.generalCategory == .nonspacingMark
        }
        guard !range.isEmpty else { return false }
        if isWord(range.lowerBound), isWord(range.lowerBound - 1) { return false }
        if isWord(range.upperBound - 1), isWord(range.upperBound) { return false }
        return true
    }

    /// Scripts that separate words by nothing: Han, kana, Bopomofo, Thai, Lao, Tibetan, Myanmar,
    /// Khmer and the CJK punctuation block (BMP only; the folded units are UTF-16 and an astral
    /// Han character is a surrogate, which is never a word character anyway).
    private static func isSpaceless(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0FFF, 0x1000...0x109F, 0x1780...0x17FF,
             0x2E80...0x2FDF, 0x3000...0x30FF, 0x3100...0x312F, 0x31F0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F:
            return true
        default:
            return false
        }
    }

    /// The source UTF-16 range a non-empty folded range covers.
    public func sourceRange(_ folded: Range<Int>) -> Range<Int> {
        sourceRanges[folded.lowerBound].lowerBound..<sourceRanges[folded.upperBound - 1].upperBound
    }

    /// The first folded index at or after a source offset.
    public func foldedIndex(atOrAfter sourceOffset: Int) -> Int {
        var low = 0
        var high = sourceRanges.count
        while low < high {
            let mid = (low + high) / 2
            if sourceRanges[mid].lowerBound < sourceOffset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Source UTF-16 ranges of every occurrence of `needle` in `haystack`, in order.
    public static func ranges(of needle: String, in haystack: String, whitespace: Whitespace = .collapsed,
                              ignoringCase: Bool = false, wholeWords: Bool = false) -> [Range<Int>] {
        let folded = FoldedText(needle, whitespace: whitespace, ignoringCase: ignoringCase)
        guard !folded.isEmpty else { return [] }
        let text = FoldedText(haystack, whitespace: whitespace, ignoringCase: ignoringCase)
        return text.occurrences(of: folded.units).map { $0..<($0 + folded.count) }
            .filter { !wholeWords || text.isWholeWords($0) }
            .map { text.sourceRange($0) }
    }

    // MARK: Scalar folding

    private static let ignorable: Set<UInt32> = [0x00AD, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF]
    private static let singleQuotes: Set<UInt32> = [0x2018, 0x2019, 0x201A, 0x201B, 0x2032, 0x02BC]
    private static let doubleQuotes: Set<UInt32> = [0x201C, 0x201D, 0x201E, 0x201F, 0x2033]
    private static let dashes: Set<UInt32> = [0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212]

    static func fold(_ scalar: Unicode.Scalar, ignoringCase: Bool) -> [UInt16] {
        let value = scalar.value
        if value < 0x80 {
            if ignoringCase, value >= 0x41, value <= 0x5A { return [UInt16(value + 0x20)] }
            return [UInt16(value)]
        }
        if ignorable.contains(value) { return [] }
        if singleQuotes.contains(value) { return [0x27] }
        if doubleQuotes.contains(value) { return [0x22] }
        if dashes.contains(value) { return [0x2D] }
        var folded = String(scalar).decomposedStringWithCompatibilityMapping
        if ignoringCase { folded = folded.lowercased() }
        return folded.unicodeScalars.filter { !$0.properties.isWhitespace }.flatMap { Array(String($0).utf16) }
    }
}
