/// The kind of a block. Open: a new element (tables, say) adds a kind and a parser.
public struct BlockKind: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let blank = BlockKind("blank")
    public static let paragraph = BlockKind("paragraph")
    public static let heading = BlockKind("heading")
    public static let listItem = BlockKind("listItem")
    public static let quote = BlockKind("quote")
    public static let codeBlock = BlockKind("codeBlock")
    public static let thematicBreak = BlockKind("thematicBreak")
}

/// The kind of an inline span. Open, like `BlockKind`.
public struct InlineKind: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let strong = InlineKind("strong")
    public static let emphasis = InlineKind("emphasis")
    public static let strikethrough = InlineKind("strikethrough")
    public static let code = InlineKind("code")
    public static let link = InlineKind("link")
    public static let autolink = InlineKind("autolink")
    public static let escape = InlineKind("escape")
}

/// Typed details some blocks carry. Elements added later can use `extra`.
public struct BlockAttributes: Hashable, Sendable {
    /// Heading level 1…6.
    public var level: Int?
    /// List items: ordered (`1.`) or bullet (`-`).
    public var ordered: Bool?
    /// Ordered list items: the number written.
    public var number: Int?
    /// List items: nesting depth from indentation (0 = top level).
    public var indent: Int?
    /// Task items: whether the box is checked. `nil` for non-task items.
    public var checked: Bool?
    /// Code blocks: the info string's first word.
    public var language: String?
    public var extra: [String: String]

    public init(level: Int? = nil, ordered: Bool? = nil, number: Int? = nil, indent: Int? = nil,
                checked: Bool? = nil, language: String? = nil, extra: [String: String] = [:]) {
        self.level = level
        self.ordered = ordered
        self.number = number
        self.indent = indent
        self.checked = checked
        self.language = language
        self.extra = extra
    }
}

/// An inline span with its exact source ranges.
public struct Inline: Hashable, Sendable {
    public var kind: InlineKind
    /// The whole span including syntax characters.
    public var range: Range<Int>
    /// The text between the syntax characters (a link's label, emphasis content, …).
    public var contentRange: Range<Int>
    /// Syntax characters (`**`, backticks, `](url)`, …) — dimmed by the editor.
    public var syntax: [Range<Int>]
    /// Links: the destination as written, and where it is.
    public var destination: String?
    public var destinationRange: Range<Int>?
    public var children: [Inline]

    public init(kind: InlineKind, range: Range<Int>, contentRange: Range<Int>, syntax: [Range<Int>],
                destination: String? = nil, destinationRange: Range<Int>? = nil, children: [Inline] = []) {
        self.kind = kind
        self.range = range
        self.contentRange = contentRange
        self.syntax = syntax
        self.destination = destination
        self.destinationRange = destinationRange
        self.children = children
    }

    /// This inline and all descendants, depth first.
    public var flattened: [Inline] { [self] + children.flatMap(\.flattened) }
}

/// A block with its exact source ranges. Blocks are line-based: one block per line, except
/// multi-line constructs such as fenced code. Container blocks (quotes) hold the block parsed
/// from the rest of their line as a child.
public struct Block: Hashable, Sendable {
    public var kind: BlockKind
    /// From the start of the block's first line to the end of its last line (no newline).
    public var range: Range<Int>
    /// The text the block carries after its markers (heading text, item text, …).
    public var contentRange: Range<Int>
    /// Marker characters (`## `, `> `, `- [ ] `, fences, …).
    public var syntax: [Range<Int>]
    public var attributes: BlockAttributes
    public var inlines: [Inline]
    public var children: [Block]

    public init(kind: BlockKind, range: Range<Int>, contentRange: Range<Int>, syntax: [Range<Int>] = [],
                attributes: BlockAttributes = BlockAttributes(), inlines: [Inline] = [], children: [Block] = []) {
        self.kind = kind
        self.range = range
        self.contentRange = contentRange
        self.syntax = syntax
        self.attributes = attributes
        self.inlines = inlines
        self.children = children
    }

    /// This block and all descendants, depth first.
    public var flattened: [Block] { [self] + children.flatMap(\.flattened) }

    /// All inlines of this block and its children.
    public var allInlines: [Inline] { flattened.flatMap { $0.inlines.flatMap(\.flattened) } }

    /// The innermost block that is not a container (what the line "is").
    public var leaf: Block { children.last?.leaf ?? self }
}

/// A parsed markdown document.
public struct MarkdownDocument: Sendable {
    public let text: MarkdownText
    public let blocks: [Block]

    public init(text: MarkdownText, blocks: [Block]) {
        self.text = text
        self.blocks = blocks
    }

    /// The top-level block covering `offset`.
    public func block(containing offset: Int) -> Block? {
        blocks.first { $0.range.contains(offset) || $0.range.upperBound == offset }
    }

    /// Every inline in the document, depth first.
    public var allInlines: [Inline] { blocks.flatMap(\.allInlines) }
}
