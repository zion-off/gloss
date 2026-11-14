extension BlockKind {
    /// A GitHub-flavoured pipe table: header row, delimiter row, body rows. Its children are its
    /// rows (`tableRow`), and theirs are cells (`tableCell`) carrying the inlines.
    public static let table = BlockKind("table")
    public static let tableRow = BlockKind("tableRow")
    public static let tableCell = BlockKind("tableCell")
}

extension MarkdownParser {
    /// The notes editor's dialect: `standard` plus pipe tables. Exporters, the CLI, search and
    /// link scanning keep `standard`, which reads a table as the paragraph lines it is written
    /// as, so their output and offsets are exactly what they were before tables existed.
    public static let notes: MarkdownParser = {
        var parser = MarkdownParser.standard
        // Just before the paragraph fallback: a line that is a heading, list item, quote, fence
        // or divider stays one, as in GitHub's dialect.
        let index = parser.blockParsers.firstIndex { $0 is ParagraphParser } ?? parser.blockParsers.endIndex
        parser.blockParsers.insert(TableParser(), at: index)
        return parser
    }()
}

/// Pipe tables. Matches only a complete, regular table: a header row, a delimiter row with the
/// same number of cells (`---`, `:--`, `--:`, `:-:`), then body rows with that number again.
/// Anything else (no delimiter row, a ragged row, a bad delimiter) is not a table at all, so its
/// lines stay paragraphs: a half-typed table never half-renders.
///
/// A row needs at least one pipe that separates cells. Pipes that are escaped (`\|`) or inside a
/// code span are cell content, so neither can change a table's shape. Body rows end at a line
/// without a separating pipe, a blank line, or a line a parser registered before this one claims
/// (a heading, list item, quote, fence).
public struct TableParser: BlockParser {
    public init() {}

    public func parse(_ slice: LineSlice, in context: BlockParsingContext) -> BlockMatch? {
        // Multi-line: declines inside a container, like fenced code.
        guard !context.isNested else { return nil }
        let text = context.text
        guard let header = TableRowScan(line: slice.range, in: text), !header.pipes.isEmpty,
              slice.lineIndex + 1 < text.lines.count,
              let delimiter = TableRowScan(line: text.lines[slice.lineIndex + 1], in: text), !delimiter.pipes.isEmpty,
              delimiter.cells.count == header.cells.count,
              let alignments = delimiter.alignments(in: text) else { return nil }

        var rows = [header, delimiter]
        var lineIndex = slice.lineIndex + 2
        while lineIndex < text.lines.count {
            let line = text.lines[lineIndex]
            guard let row = TableRowScan(line: line, in: text), !row.pipes.isEmpty,
                  !claimedEarlier(LineSlice(lineIndex: lineIndex, range: line), in: context) else { break }
            guard row.cells.count == header.cells.count else { return nil }
            rows.append(row)
            lineIndex += 1
        }

        // A cell's inlines are scanned per cell (cells are separate inline contexts, as on GitHub:
        // `| a * | b * |` is not emphasis). A cell holding none of the registered triggers or
        // delimiters can't have any, so its scan is skipped — on a wide table that is most cells.
        let inlineTriggers = Set(context.parser.inlineParsers.flatMap(\.triggers))
            .union(context.parser.delimiterCharacters.keys)

        let rowBlocks = rows.enumerated().map { index, row in
            let role: TableRowRole = index == 0 ? .header : index == 1 ? .delimiter : .body
            // A column's alignment is the header's to carry: `MarkdownTable` reads it there, and
            // the body and delimiter rows' cells stay free of data nobody reads.
            let cells = zip(row.cells, alignments).map { cell, alignment in
                let content = TableRowScan.content(of: cell, in: text)
                let inlines = role == .delimiter || !content.contains(where: { inlineTriggers.contains(text.units[$0]) })
                    ? [] : context.inlines(in: content)
                return Block(kind: .tableCell, range: cell, contentRange: content,
                             attributes: role == .header ? BlockAttributes(extra: [TableKeys.alignment: alignment.rawValue]) : BlockAttributes(),
                             inlines: inlines)
            }
            return Block(kind: .tableRow, range: row.line, contentRange: row.line, syntax: row.pipes.map { $0..<$0 + 1 },
                         attributes: BlockAttributes(extra: [TableKeys.role: role.rawValue]), children: cells)
        }
        let range = header.line.lowerBound..<rows[rows.count - 1].line.upperBound
        return BlockMatch(block: Block(kind: .table, range: range, contentRange: range, children: rowBlocks),
                          consumedLines: rows.count)
    }

    /// Whether a parser registered before this one takes the line (it then ends the table).
    private func claimedEarlier(_ slice: LineSlice, in context: BlockParsingContext) -> Bool {
        for parser in context.parser.blockParsers {
            if parser is TableParser { return false }
            if parser.parse(slice, in: context) != nil { return true }
        }
        return false
    }
}

/// Column alignment, from the delimiter row's colons.
public enum TableAlignment: String, Hashable, Sendable, Codable {
    case none, left, center, right
}

enum TableRowRole: String {
    case header, delimiter, body
}

enum TableKeys {
    static let alignment = "align"
    static let role = "row"
}

/// One line split into cells. Offsets are UTF-16 into the whole text.
struct TableRowScan {
    let line: Range<Int>
    /// Offsets of the pipes that separate cells (leading and trailing pipes included).
    let pipes: [Int]
    /// Each cell's text between its pipes, surrounding spaces included.
    let cells: [Range<Int>]

    init?(line: Range<Int>, in text: MarkdownText) {
        let units = text.units
        let start = text.firstNonBlank(in: line)
        var end = line.upperBound
        while end > start, units[end - 1].isSpaceOrTab { end -= 1 }
        guard start < end else { return nil }

        var pipes: [Int] = []
        var cursor = start
        while cursor < end {
            let unit = units[cursor]
            if unit == .backslash {
                // `\|` and `` \` `` are content; skipping any pair is safe, only those two matter here.
                cursor += 2
                continue
            }
            if unit == .backtick {
                var run = cursor
                while run < end, units[run] == .backtick { run += 1 }
                // A code span (the same run length closes it, as `CodeSpanParser` reads it) keeps its
                // pipes; unmatched backticks are plain text.
                cursor = Self.closingRun(of: run - cursor, from: run, before: end, in: units) ?? run
                continue
            }
            if unit == .pipe { pipes.append(cursor) }
            cursor += 1
        }

        let leading = units[start] == .pipe
        // A lone `|` is a leading pipe, not also a trailing one.
        let trailing = pipes.last == end - 1 && !(leading && pipes.count == 1)
        var cells: [Range<Int>] = []
        var from = start
        for (index, pipe) in pipes.enumerated() {
            if index == 0, leading { from = pipe + 1; continue }
            cells.append(from..<pipe)
            from = pipe + 1
        }
        if !trailing { cells.append(from..<end) }
        self.line = line
        self.pipes = pipes
        self.cells = cells
    }

    /// The end of the backtick run of exactly `count` that closes a code span, if the line has one.
    private static func closingRun(of count: Int, from start: Int, before end: Int, in units: [UInt16]) -> Int? {
        var cursor = start
        while cursor < end {
            guard units[cursor] == .backtick else { cursor += 1; continue }
            var run = cursor
            while run < end, units[run] == .backtick { run += 1 }
            if run - cursor == count { return run }
            cursor = run
        }
        return nil
    }

    /// A cell's text without its surrounding spaces. An empty cell's (empty) content sits after
    /// the first space, where typing into it belongs: `| | ` → `| x |`.
    static func content(of cell: Range<Int>, in text: MarkdownText) -> Range<Int> {
        let start = text.firstNonBlank(in: cell)
        var end = cell.upperBound
        while end > start, text.units[end - 1].isSpaceOrTab { end -= 1 }
        guard start == end else { return start..<end }
        let empty = min(cell.lowerBound + 1, cell.upperBound)
        return empty..<empty
    }

    /// The delimiter row's alignments, or nil when it isn't one (each cell `:?-+:?`).
    func alignments(in text: MarkdownText) -> [TableAlignment]? {
        var result: [TableAlignment] = []
        for cell in cells {
            let content = Self.content(of: cell, in: text)
            guard !content.isEmpty else { return nil }
            let units = text.units[content]
            let left = units.first == .colon, right = units.last == .colon
            let dashes = units.dropFirst(left ? 1 : 0).dropLast(right && units.count > 1 ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == .dash }) else { return nil }
            result.append(left && right ? .center : left ? .left : right ? .right : .none)
        }
        return result
    }
}

extension UInt16 {
    fileprivate static let pipe: UInt16 = 0x7C
    fileprivate static let colon: UInt16 = 0x3A
}

/// A parsed table, read from its block: rows with cell ranges, alignments, column count.
public struct MarkdownTable: Hashable, Sendable {
    public struct Cell: Hashable, Sendable {
        /// Between the cell's pipes, surrounding spaces included.
        public var range: Range<Int>
        /// The cell's text (empty for an empty cell, placed where typing into it goes).
        public var contentRange: Range<Int>
        public var inlines: [Inline]
    }

    public struct Row: Hashable, Sendable {
        /// The whole line, without its line break.
        public var line: Range<Int>
        public var cells: [Cell]
        /// Offsets of the separating pipes.
        public var pipes: [Int]

        public var hasLeadingPipe: Bool { pipes.first.map { $0 < (cells.first?.range.lowerBound ?? line.upperBound) } ?? false }
        public var hasTrailingPipe: Bool { pipes.last.map { $0 >= (cells.last?.range.upperBound ?? line.upperBound) } ?? false }
        public var isEmpty: Bool { cells.allSatisfy(\.contentRange.isEmpty) }
    }

    public let block: Block
    public let header: Row
    public let delimiter: Row
    public let body: [Row]
    public let alignments: [TableAlignment]

    public init?(_ block: Block) {
        guard block.kind == .table, block.children.count >= 2 else { return nil }
        let rows = block.children.map { row in
            Row(line: row.range, cells: row.children.map { Cell(range: $0.range, contentRange: $0.contentRange, inlines: $0.inlines) },
                pipes: row.syntax.map(\.lowerBound))
        }
        self.block = block
        header = rows[0]
        delimiter = rows[1]
        body = Array(rows.dropFirst(2))
        alignments = block.children[0].children.map { TableAlignment(rawValue: $0.attributes.extra[TableKeys.alignment] ?? "") ?? .none }
    }

    public var range: Range<Int> { block.range }
    public var columnCount: Int { header.cells.count }
    /// Every line in text order: header, delimiter, body rows.
    public var lines: [Row] { [header, delimiter] + body }
    /// The rows a grid draws (the delimiter row is not one): header, then body rows.
    public var gridRows: [Row] { [header] + body }

    /// The index into `lines` of the line holding `offset` (a line's end counts as on it).
    public func lineIndex(containing offset: Int) -> Int? {
        lines.firstIndex { $0.line.lowerBound <= offset && offset <= $0.line.upperBound }
    }

    /// The document's tables, in order: a table's ordinal is its index here.
    public static func all(in document: MarkdownDocument) -> [MarkdownTable] {
        document.blocks.compactMap(MarkdownTable.init)
    }
}
