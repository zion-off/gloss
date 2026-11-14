import GlossMarkdown

extension NotesRole {
    /// A table drawn as a grid (the caret is elsewhere): its markdown stays in the text, hidden,
    /// each line as tall as the grid row it draws.
    public static let tableGrid = StyleRole("tableGrid")
}

/// A rectangle in points, measured from a table's top-left.
public struct GridRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// Sizes of a drawn table, in points.
public struct TableGridMetrics: Hashable, Sendable {
    /// Between a cell's border and its text, left and right.
    public var cellPaddingX: Double
    /// Above and below a cell's text.
    public var cellPaddingY: Double
    /// Above and below the grid, between it and the lines around the table.
    public var margin: Double
    /// The delimiter row's line: as tall as the rule under the header it draws.
    public var ruleBand: Double
    public var cornerRadius: Double
    /// The narrowest a divider drag makes a column.
    public var minimumColumnWidth: Double
    /// How near a divider the pointer grabs it.
    public var dividerReach: Double
    /// The "+" handles' diameter.
    public var handleSize: Double

    public static let standard = TableGridMetrics(cellPaddingX: 8, cellPaddingY: 5, margin: 6, ruleBand: 1, cornerRadius: 6,
                                                  minimumColumnWidth: 44, dividerReach: 4, handleSize: 18)
}

/// Where a drawn table's parts go, from its top-left (the top of its first line, its left edge).
///
/// The grid replaces the table's markdown line for line, because TextKit lays out one paragraph
/// per line: each source line draws one band of the grid and is exactly as tall as that band.
/// The header line draws the top margin and the header row, the delimiter line the rule under
/// the header, each body line its row, and the last line also the bottom margin.
public struct TableGridLayout: Hashable, Sendable {
    public let columnWidths: [Double]
    /// Grid rows: the header, then the body rows.
    public let rowHeights: [Double]
    public let metrics: TableGridMetrics

    public init(columnWidths: [Double], rowHeights: [Double], metrics: TableGridMetrics = .standard) {
        self.columnWidths = columnWidths
        self.rowHeights = rowHeights.isEmpty ? [0] : rowHeights
        self.metrics = metrics
    }

    public var width: Double { columnWidths.reduce(0, +) }

    /// Each column's left edge, then the table's right edge.
    public var columnEdges: [Double] {
        columnWidths.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1) }
    }

    /// The height of each source line: header, delimiter, body rows.
    public var lineHeights: [Double] {
        var heights = [metrics.margin + rowHeights[0], metrics.ruleBand] + rowHeights.dropFirst()
        heights[heights.count - 1] += metrics.margin
        return heights
    }

    /// The top of each source line.
    public var lineTops: [Double] {
        lineHeights.dropLast().reduce(into: [0]) { $0.append($0[$0.count - 1] + $1) }
    }

    public var height: Double { lineHeights.reduce(0, +) }
    public var gridTop: Double { metrics.margin }
    public var gridBottom: Double { height - metrics.margin }

    /// The top of each grid row (the header's band includes the rule under it).
    public var rowTops: [Double] {
        let tops = lineTops
        return [tops[0] + metrics.margin] + tops.dropFirst(2)
    }

    /// The source line a grid row is drawn by: the header is line 0, body row `n` line `n + 1`.
    public static func lineIndex(ofGridRow row: Int) -> Int { row == 0 ? 0 : row + 1 }

    /// The grid row a source line draws, nil for the delimiter line.
    public static func gridRow(ofLine line: Int) -> Int? { line == 0 ? 0 : line == 1 ? nil : line - 1 }

    /// The horizontal rules inside the grid: under the header (in the delimiter line's band),
    /// then between body rows.
    public var rowRules: [Double] {
        guard rowHeights.count > 1 else { return [] }
        let tops = rowTops
        return [tops[0] + rowHeights[0] + metrics.ruleBand / 2] + tops.dropFirst(2)
    }

    /// A cell's box, borders included.
    public func cellFrame(row: Int, column: Int) -> GridRect {
        let edges = columnEdges
        return GridRect(x: edges[column], y: rowTops[row], width: columnWidths[column], height: rowHeights[row])
    }

    /// Where a cell's text goes: inside its padding, as wide as it wraps to.
    public func textFrame(row: Int, column: Int) -> GridRect {
        let cell = cellFrame(row: row, column: column)
        return GridRect(x: cell.x + metrics.cellPaddingX, y: cell.y + metrics.cellPaddingY,
                        width: textWidth(column: column), height: max(cell.height - 2 * metrics.cellPaddingY, 0))
    }

    /// The width a column's text wraps to.
    public func textWidth(column: Int) -> Double {
        max(columnWidths[column] - 2 * metrics.cellPaddingX, 1)
    }

    public enum Hit: Hashable, Sendable {
        /// The divider after this column (between it and the next).
        case divider(Int)
        case cell(row: Int, column: Int)
    }

    /// What is under a point: a divider between two columns (within reach), else a cell.
    /// Nil outside the grid (the margins, beyond the edges).
    public func hit(x: Double, y: Double) -> Hit? {
        guard y >= gridTop, y < gridBottom, x >= 0, x < width else { return nil }
        let edges = columnEdges
        if let divider = edges.indices.dropFirst().dropLast().first(where: { abs(edges[$0] - x) <= metrics.dividerReach }) {
            return .divider(divider - 1)
        }
        let cell = nearestCell(x: x, y: y)
        return .cell(row: cell.row, column: cell.column)
    }

    /// The cell nearest a point, for clicks anywhere on a table's lines (its margins included).
    public func nearestCell(x: Double, y: Double) -> (row: Int, column: Int) {
        let edges = columnEdges
        let column = columnWidths.indices.last { edges[$0] <= x } ?? 0
        let tops = rowTops
        let row = tops.indices.last { tops[$0] <= y } ?? 0
        return (row, column)
    }

    /// The "+" that adds a row, centred on the bottom edge.
    public var addRowHandle: GridRect {
        let size = metrics.handleSize
        return GridRect(x: width / 2 - size / 2, y: gridBottom - size / 2, width: size, height: size)
    }

    /// The "+" that adds a column, centred on the right edge.
    public var addColumnHandle: GridRect {
        let size = metrics.handleSize
        return GridRect(x: width - size / 2, y: (gridTop + gridBottom) / 2 - size / 2, width: size, height: size)
    }

    /// Natural column widths from measured single-line text widths (rows × columns): the widest
    /// cell plus padding.
    public static func naturalWidths(textWidths: [[Double]], metrics: TableGridMetrics = .standard) -> [Double] {
        guard let columns = textWidths.first?.count else { return [] }
        return (0..<columns).map { column in
            (textWidths.map { $0.indices.contains(column) ? $0[column] : 0 }.max() ?? 0) + 2 * metrics.cellPaddingX
        }
    }

    /// A row's height from its cells' wrapped text heights: the tallest, at least one line, plus padding.
    public static func rowHeight(textHeights: [Double], lineHeight: Double, metrics: TableGridMetrics = .standard) -> Double {
        max(textHeights.max() ?? 0, lineHeight) + 2 * metrics.cellPaddingY
    }
}

/// A stretch of a drawn cell's text with one style.
public struct CellTextRun: Hashable, Sendable {
    public var text: String
    public var style: TextStyle

    public init(text: String, style: TextStyle) {
        self.text = text
        self.style = style
    }
}

public enum TableCellText {
    /// A cell's text as the grid draws it: styled by the spans inside it (bold, links, code, a
    /// bold header), with markdown syntax (`**`, brackets, a link's destination, an escape's
    /// backslash) left out, since a drawn cell is never edited in place.
    public static func runs(_ content: Range<Int>, in text: MarkdownText, spans: [StyleSpan], theme: NotesTheme) -> [CellTextRun] {
        guard !content.isEmpty else { return [] }
        let local = spans.compactMap { span -> StyleSpan? in
            guard span.range.lowerBound >= content.lowerBound, span.range.upperBound <= content.upperBound else { return nil }
            var shifted = span
            shifted.range = (span.range.lowerBound - content.lowerBound)..<(span.range.upperBound - content.lowerBound)
            return shifted
        }
        var result: [CellTextRun] = []
        for run in theme.runs(for: local, length: content.count) where run.style.collapsed != true {
            let piece = text[(run.range.lowerBound + content.lowerBound)..<(run.range.upperBound + content.lowerBound)]
            if let last = result.last, last.style == run.style {
                result[result.count - 1].text += piece
            } else {
                result.append(CellTextRun(text: piece, style: run.style))
            }
        }
        return result
    }
}
