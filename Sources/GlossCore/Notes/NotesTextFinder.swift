import Foundation
import GlossMarkdown

/// Words in a notes page that a passage link can wrap.
public struct NotesTextMatch: Hashable, Sendable {
    /// UTF-16 range in the page body (as `gloss read --raw` prints it).
    public var range: Range<Int>
    /// 1-based line number.
    public var line: Int
    /// Up to 40 characters of the line before and after the words, for listings.
    public var before: String
    public var text: String
    public var after: String
    /// The destination of the link the words already sit in, if any: linking them again
    /// re-points that link instead of nesting a new one.
    public var linkDestination: String?
}

/// Finds the words `gloss link --text` names in a page, the way the editor's link gesture
/// would accept a selection: on one line, outside code, and not across a link's syntax or in
/// its destination. Matching is by whole words, whitespace-normalised, optionally case-insensitive.
public enum NotesTextFinder {
    public static func matches(of text: String, in body: String, ignoringCase: Bool = false,
                               parser: MarkdownParser = .standard) -> [NotesTextMatch] {
        let document = parser.parse(body)
        return FoldedText.ranges(of: text, in: body, whitespace: .collapsed, ignoringCase: ignoringCase, wholeWords: true)
            .compactMap { match(at: $0, in: document) }
    }

    /// The words at an exact UTF-16 range of the body; nil when a link can't wrap them there.
    public static func match(at range: Range<Int>, in body: String, parser: MarkdownParser = .standard) -> NotesTextMatch? {
        let units = body.utf16.count
        guard range.lowerBound >= 0, range.upperBound <= units, !range.isEmpty else { return nil }
        return match(at: range, in: parser.parse(body))
    }

    /// The words at `range` as they are once a link has wrapped them: the same range, one
    /// character on (after the "["), inside a link that starts where the range did. Lets a
    /// repeated `--text-offset` find the link its earlier run made; a range that starts on a
    /// link's "[" can't be linked as it is, so it never means anything else.
    public static func match(wrappedAt range: Range<Int>, in body: String, parser: MarkdownParser = .standard) -> NotesTextMatch? {
        guard range.lowerBound >= 0, !range.isEmpty, range.upperBound < body.utf16.count else { return nil }
        let document = parser.parse(body)
        let content = (range.lowerBound + 1)..<(range.upperBound + 1)
        guard document.allInlines.contains(where: {
            $0.kind == .link && $0.range.lowerBound == range.lowerBound && $0.contentRange == content
        }) else { return nil }
        return match(at: content, in: document)
    }

    static func match(at range: Range<Int>, in document: MarkdownDocument) -> NotesTextMatch? {
        let text = document.text
        // Offsets must not split a surrogate pair (an emoji): the edit would destroy it.
        func splits(_ offset: Int) -> Bool { offset < text.length && UTF16.isTrailSurrogate(text.units[offset]) }
        guard range.lowerBound >= 0, range.upperBound <= text.length, !splits(range.lowerBound), !splits(range.upperBound),
              WrapInLink.canWrap(document, selection: range),
              !text[range].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // canWrap also accepts any selection inside a link's label (it re-points that link).
        let link = document.allInlines.first {
            $0.kind == .link && $0.contentRange.lowerBound <= range.lowerBound && range.upperBound <= $0.contentRange.upperBound
        }
        let lineIndex = text.lineIndex(containing: range.lowerBound)
        let line = text.lines[lineIndex]
        let before = text[line.lowerBound..<max(line.lowerBound, range.lowerBound)]
        let after = text[min(line.upperBound, range.upperBound)..<line.upperBound]
        return NotesTextMatch(range: range, line: lineIndex + 1, before: String(before.suffix(40)), text: text[range],
                              after: String(after.prefix(40)), linkDestination: link?.destination)
    }
}
