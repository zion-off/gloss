/// A delimiter character that makes emphasis-like spans (`*`, `_`, `~`).
public struct EmphasisDelimiter: Hashable, Sendable {
    public var character: UInt16
    /// Kinds by run length used (1 → emphasis, 2 → strong, …).
    public var kinds: [Int: InlineKind]
    /// `_` may not open or close inside a word.
    public var intrawordAllowed: Bool

    public init(character: UInt16, kinds: [Int: InlineKind], intrawordAllowed: Bool) {
        self.character = character
        self.kinds = kinds
        self.intrawordAllowed = intrawordAllowed
    }

    public static let standard: [EmphasisDelimiter] = [
        EmphasisDelimiter(character: .star, kinds: [1: .emphasis, 2: .strong], intrawordAllowed: true),
        EmphasisDelimiter(character: .underscore, kinds: [1: .emphasis, 2: .strong], intrawordAllowed: false),
        EmphasisDelimiter(character: .tilde, kinds: [2: .strikethrough], intrawordAllowed: true),
    ]
}

/// Scans a range for atomic inlines, then resolves emphasis with the CommonMark delimiter
/// algorithm (flanking rules, rule of three) over the remaining text.
struct InlineScanner: Sendable {
    let text: MarkdownText
    let parser: MarkdownParser

    func parse(_ range: Range<Int>, excluding: Set<InlineKind> = []) -> [Inline] {
        guard !range.isEmpty else { return [] }
        let context = InlineParsingContext(text: text, scanner: self)
        var atoms: [Inline] = []
        var runs: [DelimiterRun] = []
        let delimiterChars = Dictionary(parser.delimiters.map { ($0.character, $0) }, uniquingKeysWith: { a, _ in a })
        var cursor = range.lowerBound
        let limit = range.upperBound
        scan: while cursor < limit {
            let unit = text.units[cursor]
            for inlineParser in parser.inlineParsers where inlineParser.triggers.contains(unit) {
                if let inline = inlineParser.parse(at: cursor, limit: limit, in: context), !excluding.contains(inline.kind) {
                    atoms.append(inline)
                    cursor = inline.range.upperBound
                    continue scan
                }
            }
            if let delimiter = delimiterChars[unit] {
                var end = cursor
                while end < limit, text.units[end] == unit { end += 1 }
                runs.append(makeRun(delimiter, start: cursor, end: end, range: range))
                cursor = end
                continue
            }
            cursor += 1
        }
        let emphasis = resolve(runs)
        return nest(atoms + emphasis)
    }

    // MARK: Delimiter runs

    struct DelimiterRun {
        let delimiter: EmphasisDelimiter
        var start: Int
        var end: Int
        let originalLength: Int
        let canOpen: Bool
        let canClose: Bool
        var length: Int { end - start }
    }

    private enum CharClass { case whitespace, punctuation, other }

    private func classify(_ scalar: Unicode.Scalar?) -> CharClass {
        guard let scalar else { return .whitespace }
        if scalar.properties.isWhitespace { return .whitespace }
        let category = scalar.properties.generalCategory
        switch category {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation, .mathSymbol,
             .currencySymbol, .modifierSymbol, .otherSymbol:
            return .punctuation
        default:
            return .other
        }
    }

    private func makeRun(_ delimiter: EmphasisDelimiter, start: Int, end: Int, range: Range<Int>) -> DelimiterRun {
        let before = classify(start > range.lowerBound ? text.scalar(at: start, before: true) : nil)
        let after = classify(end < range.upperBound ? text.scalar(at: end) : nil)
        let leftFlanking = after != .whitespace && (after != .punctuation || before != .other)
        let rightFlanking = before != .whitespace && (before != .punctuation || after != .other)
        let canOpen: Bool, canClose: Bool
        if delimiter.intrawordAllowed {
            canOpen = leftFlanking
            canClose = rightFlanking
        } else {
            canOpen = leftFlanking && (!rightFlanking || before == .punctuation)
            canClose = rightFlanking && (!leftFlanking || after == .punctuation)
        }
        return DelimiterRun(delimiter: delimiter, start: start, end: end, originalLength: end - start, canOpen: canOpen, canClose: canClose)
    }

    private func resolve(_ input: [DelimiterRun]) -> [Inline] {
        var runs = input
        var result: [Inline] = []
        var closerIndex = 0
        while closerIndex < runs.count {
            let closer = runs[closerIndex]
            guard closer.canClose, closer.length > 0 else { closerIndex += 1; continue }
            var matched = false
            var openerIndex = closerIndex - 1
            while openerIndex >= 0 {
                let opener = runs[openerIndex]
                if opener.length > 0, opener.canOpen, opener.delimiter == closer.delimiter, ruleOfThreeAllows(opener, closer),
                   let use = usableLength(opener: opener, closer: closer) {
                    let kind = closer.delimiter.kinds[use]!
                    let openSyntax = opener.end - use..<opener.end
                    let closeSyntax = closer.start..<closer.start + use
                    result.append(Inline(kind: kind, range: openSyntax.lowerBound..<closeSyntax.upperBound,
                                         contentRange: openSyntax.upperBound..<closeSyntax.lowerBound,
                                         syntax: [openSyntax, closeSyntax]))
                    runs[openerIndex].end -= use
                    runs[closerIndex].start += use
                    // Delimiters between opener and closer can no longer match.
                    for between in (openerIndex + 1)..<closerIndex { runs[between].end = runs[between].start }
                    matched = true
                    break
                }
                openerIndex -= 1
            }
            if !matched || runs[closerIndex].length == 0 { closerIndex += 1 }
        }
        return result
    }

    private func usableLength(opener: DelimiterRun, closer: DelimiterRun) -> Int? {
        let available = min(opener.length, closer.length)
        let lengths = closer.delimiter.kinds.keys.sorted(by: >)
        if closer.delimiter.kinds.count == 1, let only = lengths.first {
            // Single-kind delimiters (strikethrough) need exact runs.
            return opener.length == only && closer.length == only ? only : nil
        }
        return lengths.first { $0 <= available }
    }

    private func ruleOfThreeAllows(_ opener: DelimiterRun, _ closer: DelimiterRun) -> Bool {
        guard opener.canClose || closer.canOpen else { return true }
        let sum = opener.originalLength + closer.originalLength
        return sum % 3 != 0 || (opener.originalLength % 3 == 0 && closer.originalLength % 3 == 0)
    }

    // MARK: Tree building

    /// Nests spans by containment. Emphasis that would cross an atomic inline is dropped.
    private func nest(_ inlines: [Inline]) -> [Inline] {
        let sorted = inlines.sorted { a, b in
            a.range.lowerBound != b.range.lowerBound ? a.range.lowerBound < b.range.lowerBound : a.range.count > b.range.count
        }
        var roots: [Inline] = []
        var stack: [Inline] = []

        func popInto() {
            let finished = stack.removeLast()
            if stack.isEmpty { roots.append(finished) } else { stack[stack.count - 1].children.append(finished) }
        }

        for inline in sorted {
            while let top = stack.last, top.range.upperBound <= inline.range.lowerBound { popInto() }
            if let top = stack.last {
                // Crossing spans: keep the one already open.
                guard inline.range.upperBound <= top.range.upperBound else { continue }
                // Atomic inlines are leaves; emphasis inside them was not scanned.
                guard top.kind != .code, top.kind != .escape, top.kind != .autolink else { continue }
                if top.kind == .link, inline.range.lowerBound < top.contentRange.lowerBound || inline.range.upperBound > top.contentRange.upperBound { continue }
            }
            stack.append(inline)
        }
        while !stack.isEmpty { popInto() }
        return roots
    }
}
