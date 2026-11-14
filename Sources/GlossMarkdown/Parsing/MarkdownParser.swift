/// Parses markdown into blocks and inlines with exact UTF-16 source ranges.
///
/// Extensible: block parsers, inline parsers and emphasis delimiters are registered lists, so a
/// new element (tables, images, …) is added by registering a parser, not by editing this type.
public struct MarkdownParser: Sendable {
    public var blockParsers: [any BlockParser]
    public var inlineParsers: [any InlineParser]
    public var delimiters: [EmphasisDelimiter] {
        didSet { delimiterCharacters = Self.delimiterCharacters(for: delimiters) }
    }
    /// The delimiters keyed by character, for the scanner's per-unit lookup. Built once here, not
    /// on every inline scan: a table parses each cell's inlines separately, so a scan per cell
    /// made the dictionary's cost per cell too.
    public private(set) var delimiterCharacters: [UInt16: EmphasisDelimiter]

    public init(blockParsers: [any BlockParser], inlineParsers: [any InlineParser], delimiters: [EmphasisDelimiter]) {
        self.blockParsers = blockParsers
        self.inlineParsers = inlineParsers
        self.delimiters = delimiters
        self.delimiterCharacters = Self.delimiterCharacters(for: delimiters)
    }

    static func delimiterCharacters(for delimiters: [EmphasisDelimiter]) -> [UInt16: EmphasisDelimiter] {
        Dictionary(delimiters.map { ($0.character, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The v1 dialect: headings, emphasis, lists, task lists, quotes, code, links, dividers.
    public static let standard = MarkdownParser(
        blockParsers: [
            BlankLineParser(), FencedCodeParser(), HeadingParser(), ThematicBreakParser(),
            QuoteParser(), ListItemParser(), ParagraphParser(),
        ],
        inlineParsers: [EscapeParser(), CodeSpanParser(), AutolinkParser(), LinkParser()],
        delimiters: EmphasisDelimiter.standard
    )

    public func parse(_ string: String) -> MarkdownDocument {
        parse(MarkdownText(string))
    }

    public func parse(_ text: MarkdownText) -> MarkdownDocument {
        let context = BlockParsingContext(text: text, parser: self)
        var blocks: [Block] = []
        var lineIndex = 0
        while lineIndex < text.lines.count {
            let slice = LineSlice(lineIndex: lineIndex, range: text.lines[lineIndex])
            let match = context.parseSlice(slice, nested: false)
            blocks.append(match.block)
            lineIndex += max(1, match.consumedLines)
        }
        return MarkdownDocument(text: text, blocks: blocks)
    }

    /// Parses the inline content of `range` (used by block parsers and by tests).
    public func parseInlines(in text: MarkdownText, range: Range<Int>) -> [Inline] {
        InlineScanner(text: text, parser: self).parse(range)
    }
}

/// The part of a line a block parser looks at. For nested parsing (inside a quote) it starts
/// after the container's markers.
public struct LineSlice: Hashable, Sendable {
    public let lineIndex: Int
    public let range: Range<Int>

    public init(lineIndex: Int, range: Range<Int>) {
        self.lineIndex = lineIndex
        self.range = range
    }
}

public struct BlockMatch: Sendable {
    public var block: Block
    /// Whole lines consumed, at least 1. Nested parses always consume exactly one.
    public var consumedLines: Int

    public init(block: Block, consumedLines: Int = 1) {
        self.block = block
        self.consumedLines = consumedLines
    }
}

/// Recognises one kind of block at the start of a line slice.
public protocol BlockParser: Sendable {
    func parse(_ slice: LineSlice, in context: BlockParsingContext) -> BlockMatch?
}

/// What block parsers can see and do.
public struct BlockParsingContext: Sendable {
    public let text: MarkdownText
    let parser: MarkdownParser
    /// True while parsing the rest of a line inside a container (multi-line blocks decline).
    public private(set) var isNested = false

    init(text: MarkdownText, parser: MarkdownParser) {
        self.text = text
        self.parser = parser
    }

    public func inlines(in range: Range<Int>) -> [Inline] {
        parser.parseInlines(in: text, range: range)
    }

    /// Runs the parser chain on a slice. Used by container parsers for their content.
    public func parseSlice(_ slice: LineSlice, nested: Bool) -> BlockMatch {
        var context = self
        context.isNested = nested
        for blockParser in parser.blockParsers {
            if var match = blockParser.parse(slice, in: context) {
                if nested { match.consumedLines = 1 }
                return match
            }
        }
        // ParagraphParser always matches; this is only reached with a custom parser list.
        return BlockMatch(block: Block(kind: .paragraph, range: slice.range, contentRange: slice.range,
                                       inlines: inlines(in: slice.range)))
    }
}
