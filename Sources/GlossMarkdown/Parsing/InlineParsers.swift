/// Recognises an atomic inline (code span, link, …) starting exactly at `index`.
/// Emphasis is not an `InlineParser`; it is resolved afterwards from `EmphasisDelimiter`s.
public protocol InlineParser: Sendable {
    /// UTF-16 units that can start this inline.
    var triggers: Set<UInt16> { get }
    func parse(at index: Int, limit: Int, in context: InlineParsingContext) -> Inline?
}

public struct InlineParsingContext: Sendable {
    public let text: MarkdownText
    let scanner: InlineScanner

    /// Parses nested inline content (a link label, say), excluding parsers of `excluding` kind.
    public func inlines(in range: Range<Int>, excluding: Set<InlineKind> = []) -> [Inline] {
        scanner.parse(range, excluding: excluding)
    }
}

/// `\*` — a backslash before ASCII punctuation makes it literal.
public struct EscapeParser: InlineParser {
    public init() {}
    public var triggers: Set<UInt16> { [.backslash] }
    public func parse(at index: Int, limit: Int, in context: InlineParsingContext) -> Inline? {
        guard index + 1 < limit, let next = context.text.unit(at: index + 1), next.isASCIIPunctuation else { return nil }
        return Inline(kind: .escape, range: index..<index + 2, contentRange: index + 1..<index + 2, syntax: [index..<index + 1])
    }
}

/// `` `code` `` — a backtick run closed by a run of the same length.
public struct CodeSpanParser: InlineParser {
    public init() {}
    public var triggers: Set<UInt16> { [.backtick] }

    public func parse(at index: Int, limit: Int, in context: InlineParsingContext) -> Inline? {
        let units = context.text.units
        // Only start at the beginning of a backtick run.
        if index > 0, units[index - 1] == .backtick { return nil }
        let openCount = runLength(units, from: index, limit: limit)
        var cursor = index + openCount
        while cursor < limit {
            if units[cursor] == .backtick {
                let count = runLength(units, from: cursor, limit: limit)
                if count == openCount {
                    return Inline(kind: .code, range: index..<cursor + count, contentRange: index + openCount..<cursor,
                                  syntax: [index..<index + openCount, cursor..<cursor + count])
                }
                cursor += count
            } else {
                cursor += 1
            }
        }
        return nil
    }

    private func runLength(_ units: [UInt16], from start: Int, limit: Int) -> Int {
        var end = start
        while end < limit, units[end] == .backtick { end += 1 }
        return end - start
    }
}

/// `<https://example.com>` and `<gloss://…>`.
public struct AutolinkParser: InlineParser {
    public init() {}
    public var triggers: Set<UInt16> { [.lt] }

    public func parse(at index: Int, limit: Int, in context: InlineParsingContext) -> Inline? {
        let units = context.text.units
        var cursor = index + 1
        var sawColon = false
        while cursor < limit, units[cursor] != .gt {
            if units[cursor] == .space || units[cursor] == .lt { return nil }
            if units[cursor] == 0x3A { sawColon = true }
            cursor += 1
        }
        guard cursor < limit, sawColon, cursor > index + 3 else { return nil }
        let destination = index + 1..<cursor
        // The scheme must be letters followed by a colon.
        let scheme = context.text[destination].prefix { $0 != ":" }
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0 == "+" || $0 == "-" || $0 == "." }) else { return nil }
        return Inline(kind: .autolink, range: index..<cursor + 1, contentRange: destination,
                      syntax: [index..<index + 1, cursor..<cursor + 1],
                      destination: context.text[destination], destinationRange: destination)
    }
}

/// `[label](destination "optional title")`. Labels may contain emphasis and code, not links.
public struct LinkParser: InlineParser {
    public init() {}
    public var triggers: Set<UInt16> { [.lbracket] }

    public func parse(at index: Int, limit: Int, in context: InlineParsingContext) -> Inline? {
        let text = context.text
        let units = text.units
        guard let labelEnd = closingBracket(units, from: index, limit: limit) else { return nil }
        let openParen = labelEnd + 1
        guard openParen < limit, units[openParen] == .lparen else { return nil }
        var cursor = openParen + 1
        while cursor < limit, units[cursor].isSpaceOrTab { cursor += 1 }
        let destination: Range<Int>
        if cursor < limit, units[cursor] == .lt {
            var end = cursor + 1
            while end < limit, units[end] != .gt, units[end] != .newline { end += 1 }
            guard end < limit, units[end] == .gt else { return nil }
            destination = cursor + 1..<end
            cursor = end + 1
        } else {
            let start = cursor
            var depth = 0
            while cursor < limit {
                let unit = units[cursor]
                if unit == .backslash, cursor + 1 < limit { cursor += 2; continue }
                if unit.isSpaceOrTab { break }
                if unit == .lparen { depth += 1 }
                if unit == .rparen { if depth == 0 { break }; depth -= 1 }
                cursor += 1
            }
            destination = start..<cursor
        }
        while cursor < limit, units[cursor].isSpaceOrTab { cursor += 1 }
        // Optional title.
        if cursor < limit, let close = titleCloser(units[cursor]) {
            var end = cursor + 1
            while end < limit, units[end] != close { end += units[end] == .backslash ? 2 : 1 }
            guard end < limit else { return nil }
            cursor = end + 1
            while cursor < limit, units[cursor].isSpaceOrTab { cursor += 1 }
        }
        guard cursor < limit, units[cursor] == .rparen else { return nil }
        let label = index + 1..<labelEnd
        let children = context.inlines(in: label, excluding: [.link, .autolink])
        return Inline(kind: .link, range: index..<cursor + 1, contentRange: label,
                      syntax: [index..<index + 1, labelEnd..<cursor + 1],
                      destination: text[destination], destinationRange: destination, children: children)
    }

    private func titleCloser(_ unit: UInt16) -> UInt16? {
        switch unit {
        case .quote: .quote
        case .apostrophe: .apostrophe
        default: nil
        }
    }

    /// The matching `]`, honouring nesting, escapes and code spans.
    private func closingBracket(_ units: [UInt16], from start: Int, limit: Int) -> Int? {
        var depth = 0
        var cursor = start
        while cursor < limit {
            switch units[cursor] {
            case .backslash:
                cursor += 2
                continue
            case .backtick:
                var run = cursor
                while run < limit, units[run] == .backtick { run += 1 }
                let count = run - cursor
                var search = run
                var closed = false
                while search < limit {
                    if units[search] == .backtick {
                        var end = search
                        while end < limit, units[end] == .backtick { end += 1 }
                        if end - search == count { cursor = end; closed = true; break }
                        search = end
                    } else { search += 1 }
                }
                if !closed { cursor = run }
                continue
            case .lbracket:
                depth += 1
            case .rbracket:
                depth -= 1
                if depth == 0 { return cursor }
            default:
                break
            }
            cursor += 1
        }
        return nil
    }
}
