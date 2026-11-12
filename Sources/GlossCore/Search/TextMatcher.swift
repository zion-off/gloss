import Foundation

/// Case- and diacritic-insensitive prefix matching of query words against text. Used to
/// find and highlight hits inside pages, and by the in-memory full-text index.
public struct TextMatcher: Sendable {
    /// Folded query words.
    public let tokens: [String]

    public init(query: String) {
        tokens = Self.words(in: query).map(\.folded)
    }

    public var isEmpty: Bool { tokens.isEmpty }

    public static func fold(_ text: some StringProtocol) -> String {
        String(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    public struct Word: Sendable {
        public var range: Range<String.Index>
        public var folded: String
    }

    /// Splits `text` into words (runs of letters and digits).
    public static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let isWordChar = text[index].isLetter || text[index].isNumber
            if isWordChar, start == nil { start = index }
            if !isWordChar, let s = start {
                result.append(Word(range: s..<index, folded: fold(text[s..<index])))
                start = nil
            }
            index = text.index(after: index)
        }
        if let s = start { result.append(Word(range: s..<text.endIndex, folded: fold(text[s...]))) }
        return result
    }

    private func isMatch(_ word: Word) -> Bool {
        tokens.contains { word.folded.hasPrefix($0) }
    }

    /// True when every query word prefix-matches some word of `text`.
    public func matches(_ text: String) -> Bool {
        guard !tokens.isEmpty else { return false }
        let words = Self.words(in: text).map(\.folded)
        return tokens.allSatisfy { token in words.contains { $0.hasPrefix(token) } }
    }

    /// Ranges of all words in `text` that match a query word.
    public func matchRanges(in text: String) -> [Range<String.Index>] {
        Self.words(in: text).filter(isMatch).map(\.range)
    }

    /// The first match as a UTF-16 range (what `NSRange`/the editor uses).
    public func firstMatchUTF16(in text: String) -> Range<Int>? {
        guard let range = matchRanges(in: text).first else { return nil }
        let lower = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.utf16.distance(from: text.startIndex, to: range.upperBound)
        return lower..<upper
    }

    /// Number of matching words (a crude relevance score).
    public func score(_ text: String) -> Int {
        Self.words(in: text).filter(isMatch).count
    }

    /// An excerpt of about `radius` words either side of the first match.
    public func snippet(of text: String, radius: Int = 8) -> Snippet {
        let words = Self.words(in: text)
        guard !words.isEmpty else { return Snippet(segments: []) }
        let firstHit = words.firstIndex(where: isMatch) ?? 0
        let startWord = max(0, firstHit - radius)
        let endWord = min(words.count - 1, firstHit + radius)
        let lower = startWord == 0 ? text.startIndex : words[startWord].range.lowerBound
        let upper = endWord == words.count - 1 ? text.endIndex : words[endWord].range.upperBound
        var segments: [Snippet.Segment] = []
        if startWord > 0 { segments.append(.init(text: "…", isMatch: false)) }
        var cursor = lower
        for word in words[startWord...endWord] where isMatch(word) {
            if cursor < word.range.lowerBound {
                segments.append(.init(text: Self.flatten(text[cursor..<word.range.lowerBound]), isMatch: false))
            }
            segments.append(.init(text: String(text[word.range]), isMatch: true))
            cursor = word.range.upperBound
        }
        if cursor < upper { segments.append(.init(text: Self.flatten(text[cursor..<upper]), isMatch: false)) }
        if endWord < words.count - 1 { segments.append(.init(text: "…", isMatch: false)) }
        return Snippet(segments: segments)
    }

    private static func flatten(_ text: Substring) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }
}
