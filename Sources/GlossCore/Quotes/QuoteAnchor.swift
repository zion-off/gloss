import Foundation

/// A passage pinned by its words rather than by an engine position: the exact quote, a little
/// context on either side, and which occurrence of the quote it is within its section or page
/// (docs/DECISIONS.md D-190). The CLI makes these from extracted text; a reader resolves them
/// against the text it shows, which may differ slightly (spaces between blocks, ligatures).
///
/// The resolution here is mirrored in TypeScript by `web/src/bridge/quote.ts`; both run the
/// shared cases in `Tests/Fixtures/quotes/resolve.json`.
public struct QuoteAnchor: Hashable, Codable, Sendable {
    /// The quoted text, whitespace-normalised.
    public var text: String
    /// Up to `contextLength` characters right before the quote (whitespace-normalised).
    public var prefix: String
    /// Up to `contextLength` characters right after it.
    public var suffix: String
    /// 0-based: which match of `text` this is, counting whitespace-insensitive, case-sensitive
    /// matches from the start of its section or page.
    public var occurrence: Int

    public static let contextLength = 32

    public init(text: String, prefix: String = "", suffix: String = "", occurrence: Int = 0) {
        self.text = text
        self.prefix = prefix
        self.suffix = suffix
        self.occurrence = occurrence
    }

    /// The anchor for a UTF-16 range of `source` (which must fall on scalar boundaries). To anchor
    /// many ranges of one text, use `QuoteAnchoring`, which folds it once.
    public init(range: Range<Int>, in source: String) {
        var anchoring = QuoteAnchoring(source)
        self = anchoring.anchor(for: range)
    }

    /// Where the anchored passage is in `source` now, as a UTF-16 range; nil when it can't be
    /// found. Context decides between several matches and the occurrence index breaks ties; a
    /// case-insensitive match is the fallback, then the quote's first and last words.
    public func resolve(in source: String) -> Range<Int>? {
        let quote = FoldedText(text, whitespace: .stripped)
        guard !quote.isEmpty else { return nil }
        for ignoringCase in [false, true] {
            let folded = ignoringCase ? FoldedText(source, whitespace: .stripped, ignoringCase: true)
                                      : FoldedText(source, whitespace: .stripped)
            let needle = ignoringCase ? FoldedText(text, whitespace: .stripped, ignoringCase: true).units : quote.units
            let starts = folded.occurrences(of: needle)
            if let best = pick(starts, length: needle.count, in: folded, ignoringCase: ignoringCase) {
                return folded.sourceRange(best..<(best + needle.count))
            }
        }
        return resolveByEnds(in: FoldedText(source, whitespace: .stripped), quote: quote.units)
    }

    // MARK: Picking among matches

    /// The best of several matches: most context agreeing, then the stored occurrence, then the
    /// one nearest to it.
    func pick(_ starts: [Int], length: Int, in text: FoldedText, ignoringCase: Bool) -> Int? {
        guard !starts.isEmpty else { return nil }
        if starts.count == 1 { return starts[0] }
        let before = FoldedText(prefix, whitespace: .stripped, ignoringCase: ignoringCase).units
        let after = FoldedText(suffix, whitespace: .stripped, ignoringCase: ignoringCase).units
        let scores = starts.map { start in
            Self.commonSuffix(before, text.units, end: start) + Self.commonPrefix(after, text.units, from: start + length)
        }
        let top = scores.max() ?? 0
        let tied = starts.indices.filter { scores[$0] == top }
        let chosen = tied.min { abs($0 - occurrence) < abs($1 - occurrence) } ?? tied[0]
        return starts[chosen]
    }

    /// The quote's first and last few characters, when the middle differs (an image's alt text,
    /// a footnote marker): the head with the best agreeing prefix, then the nearest tail after it.
    func resolveByEnds(in text: FoldedText, quote: [UInt16]) -> Range<Int>? {
        let end = Self.endLength
        guard quote.count > 2 * end else { return nil }
        let head = Array(quote[..<end])
        let tail = Array(quote[(quote.count - end)...])
        let before = FoldedText(prefix, whitespace: .stripped).units
        let after = FoldedText(suffix, whitespace: .stripped).units
        var best: (range: Range<Int>, score: Int)?
        for start in text.occurrences(of: head) {
            let windowEnd = min(text.count, start + quote.count * 2 + 64)
            guard start + end <= windowEnd,
                  let tailStart = text.occurrences(of: tail, in: (start + end)..<windowEnd).first else { continue }
            let score = Self.commonSuffix(before, text.units, end: start) + Self.commonPrefix(after, text.units, from: tailStart + end)
            if best == nil || score > best!.score { best = (start..<(tailStart + end), score) }
        }
        // Without any agreeing context the ends alone are too weak to trust.
        guard let best, best.score > 0 || (before.isEmpty && after.isEmpty) else { return nil }
        return text.sourceRange(best.range)
    }

    static let endLength = 16

    static func commonSuffix(_ context: [UInt16], _ units: [UInt16], end: Int) -> Int {
        var count = 0
        while count < context.count, end - count - 1 >= 0, context[context.count - 1 - count] == units[end - count - 1] { count += 1 }
        return count
    }

    static func commonPrefix(_ context: [UInt16], _ units: [UInt16], from start: Int) -> Int {
        var count = 0
        while count < context.count, start + count < units.count, context[count] == units[start + count] { count += 1 }
        return count
    }
}

/// Anchors for many ranges of one text: the text is folded once and each quote's matches are
/// counted once, so listing every match in a long chapter stays linear.
public struct QuoteAnchoring: Sendable {
    let units: [UInt16]
    let stripped: FoldedText
    private var occurrences: [[UInt16]: [Int]] = [:]

    public init(_ source: String) {
        units = Array(source.utf16)
        stripped = FoldedText(source, whitespace: .stripped)
    }

    public mutating func anchor(for range: Range<Int>) -> QuoteAnchor {
        func slice(_ r: Range<Int>) -> String { String(decoding: units[r], as: UTF16.self) }
        let length = QuoteAnchor.contextLength
        let lower = max(0, min(range.lowerBound, units.count))
        let upper = max(lower, min(range.upperBound, units.count))
        let text = Passage.normalize(slice(lower..<upper))
        let before = Passage.normalize(slice(max(0, lower - 4 * length)..<lower))
        let after = Passage.normalize(slice(upper..<min(units.count, upper + 4 * length)))
        let quote = FoldedText(text, whitespace: .stripped).units
        let starts = occurrences[quote] ?? stripped.occurrences(of: quote)
        occurrences[quote] = starts
        let start = stripped.foldedIndex(atOrAfter: lower)
        // `starts` is sorted: binary search for this match.
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] < start { low = mid + 1 } else { high = mid }
        }
        let occurrence = low < starts.count && starts[low] == start ? low : 0
        return QuoteAnchor(text: text, prefix: String(before.suffix(length)), suffix: String(after.prefix(length)),
                           occurrence: occurrence)
    }
}
