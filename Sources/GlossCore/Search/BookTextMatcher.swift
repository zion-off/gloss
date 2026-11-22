import Foundation

/// Finds a query in book text the way the readers highlight it: the whole query as typed,
/// anywhere (not only at word starts), ignoring case and accents, with any run of spaces or line
/// breaks as one space. So every match a reader draws has its own search result.
public struct BookTextMatcher: Sendable {
    let needle: [UInt16]

    public init(query: String) {
        needle = Self.fold(query).units
    }

    public var isEmpty: Bool { needle.isEmpty }

    /// UTF-16 ranges of every match in `text`, in order and never overlapping.
    public func ranges(in text: String) -> [Range<Int>] {
        guard !needle.isEmpty else { return [] }
        let folded = Self.fold(text)
        var ranges: [Range<Int>] = []
        var next = 0
        for start in folded.occurrences(of: needle) where start >= next {
            ranges.append(folded.sourceRange(start..<(start + needle.count)))
            next = start + needle.count
        }
        return ranges
    }

    private static func fold(_ text: String) -> FoldedText {
        FoldedText(text, whitespace: .collapsed, ignoringCase: true, ignoringDiacritics: true)
    }
}

extension Snippet {
    /// The text around one match, whitespace collapsed, cut at word edges where it can be, with
    /// an ellipsis where it was cut. `units` is the UTF-16 text the match range points into.
    /// Works on the units, not on characters: a common word in a long book has thousands of these.
    static func excerpt(around match: Range<Int>, in units: [UInt16], before: Int = 40, after: Int = 80) -> Snippet {
        var lower = max(0, match.lowerBound - before)
        if lower > 0, let space = (lower..<match.lowerBound).first(where: { isSpace(units[$0]) }) { lower = space + 1 }
        if lower > 0, lower < match.lowerBound, UTF16.isTrailSurrogate(units[lower]) { lower += 1 }
        var upper = min(units.count, match.upperBound + after)
        if upper < units.count, let space = (match.upperBound..<upper).last(where: { isSpace(units[$0]) }) { upper = space }
        if upper < units.count, upper > match.upperBound, UTF16.isLeadSurrogate(units[upper - 1]) { upper -= 1 }

        var head = collapsed(units[lower..<match.lowerBound])
        while head.first == 0x20 { head.removeFirst() }
        var tail = collapsed(units[match.upperBound..<upper])
        while tail.last == 0x20 { tail.removeLast() }
        if lower > 0 { head.insert(0x2026, at: 0) }
        if upper < units.count { tail.append(0x2026) }
        var segments: [Segment] = []
        if !head.isEmpty { segments.append(.init(text: string(head), isMatch: false)) }
        segments.append(.init(text: string(collapsed(units[match])), isMatch: true))
        if !tail.isEmpty { segments.append(.init(text: string(tail), isMatch: false)) }
        return Snippet(segments: segments)
    }

    /// UTF-16 to a string, writing its UTF-8 directly: `String(decoding:as: UTF16.self)` takes a
    /// generic slow path that cost more than everything else in a search. A lone surrogate
    /// becomes U+FFFD, as it would there.
    private static func string(_ units: [UInt16]) -> String {
        String(unsafeUninitializedCapacity: units.count * 3) { bytes in
            var count = 0
            func put(_ byte: UInt32) { bytes[count] = UInt8(truncatingIfNeeded: byte); count += 1 }
            var index = 0
            while index < units.count {
                var scalar = UInt32(units[index])
                index += 1
                if UTF16.isLeadSurrogate(units[index - 1]) {
                    if index < units.count, UTF16.isTrailSurrogate(units[index]) {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (UInt32(units[index]) - 0xDC00)
                        index += 1
                    } else {
                        scalar = 0xFFFD
                    }
                } else if UTF16.isTrailSurrogate(units[index - 1]) {
                    scalar = 0xFFFD
                }
                switch scalar {
                case ..<0x80: put(scalar)
                case ..<0x800: put(0xC0 | scalar >> 6); put(0x80 | scalar & 0x3F)
                case ..<0x10000: put(0xE0 | scalar >> 12); put(0x80 | scalar >> 6 & 0x3F); put(0x80 | scalar & 0x3F)
                default:
                    put(0xF0 | scalar >> 18); put(0x80 | scalar >> 12 & 0x3F); put(0x80 | scalar >> 6 & 0x3F); put(0x80 | scalar & 0x3F)
                }
            }
            return count
        }
    }

    /// The units with every run of whitespace (line breaks too) as one space.
    private static func collapsed(_ units: ArraySlice<UInt16>) -> [UInt16] {
        var result: [UInt16] = []
        result.reserveCapacity(units.count)
        for unit in units {
            if isSpace(unit) {
                if result.last != 0x20 { result.append(0x20) }
            } else {
                result.append(unit)
            }
        }
        return result
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        if unit < 0x80 { return unit == 0x20 || (0x09...0x0D).contains(unit) }
        return Unicode.Scalar(unit)?.properties.isWhitespace ?? false  // surrogates are never spaces
    }
}
