import AppKit
import GlossAppModel
import GlossMarkdown
import GlossNotes

/// Lays out the tables the model draws as grids: styles each cell's text through the notes
/// theme, measures it, and hands the measurements to `TableWidths` and `TableGridLayout`, which
/// decide everything. Measuring is the only part that needs AppKit.
@MainActor final class TableGridBuilder {
    let metrics = TableGridMetrics.standard
    private let theme: NotesEditorTheme
    private let notesTheme: NotesTheme
    /// A table's measured content, keyed by everything it depends on, so a keystroke elsewhere in
    /// the page doesn't measure every table again.
    private var cache: [Key: Content] = [:]

    private struct Key: Hashable {
        let source: String
        /// The spans inside the table, relative to its start.
        let spans: [StyleSpan]
        let fractions: [Double]?
        let available: Double
    }

    private struct Content {
        let layout: TableGridLayout
        let cells: [[NSAttributedString]]
    }

    private static let measuring: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    init(theme: NotesEditorTheme, notesTheme: NotesTheme) {
        self.theme = theme
        self.notesTheme = notesTheme
    }

    /// The grids for `tables` in a text container `containerWidth` wide whose lines are inset by
    /// `padding` on each side.
    func build(_ tables: [NotesEditorModel.GridTable], text: MarkdownText, spans: [StyleSpan],
               containerWidth: CGFloat, padding: CGFloat) -> [RenderedTable] {
        let available = max(Double(containerWidth - 2 * padding), metrics.minimumColumnWidth)
        var kept: [Key: Content] = [:]
        let rendered = tables.map { grid -> RenderedTable in
            let range = grid.table.range
            let local = spans.compactMap { span -> StyleSpan? in
                guard span.range.lowerBound >= range.lowerBound, span.range.upperBound <= range.upperBound else { return nil }
                var shifted = span
                shifted.range = (span.range.lowerBound - range.lowerBound)..<(span.range.upperBound - range.lowerBound)
                shifted.element = span.element.map { ($0.lowerBound - range.lowerBound)..<($0.upperBound - range.lowerBound) }
                return shifted
            }
            let key = Key(source: text[range], spans: local, fractions: grid.columnFractions, available: available)
            let content = kept[key] ?? cache[key] ?? measure(grid, text: text, spans: spans, available: available)
            kept[key] = content
            return RenderedTable(ordinal: grid.ordinal, lines: grid.table.lines.map(\.line), layout: content.layout,
                                 cells: content.cells, originX: padding)
        }
        cache = kept  // only what is drawn now
        return rendered
    }

    private func measure(_ grid: NotesEditorModel.GridTable, text: MarkdownText, spans: [StyleSpan], available: Double) -> Content {
        let table = grid.table
        let cells = table.gridRows.map { row in
            row.cells.enumerated().map { column, cell in
                attributed(cell.contentRange, alignment: table.alignments.indices.contains(column) ? table.alignments[column] : .none,
                           text: text, spans: spans)
            }
        }
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let textWidths = cells.map { row in row.map { Double($0.boundingRect(with: unbounded, options: Self.measuring, context: nil).width.rounded(.up)) } }
        let natural = TableGridLayout.naturalWidths(textWidths: textWidths, metrics: metrics)
        let widths = grid.columnFractions.map { TableWidths.widths(fractions: $0, available: available) }
            ?? TableWidths.automatic(natural: natural, available: available)
        let columns = TableGridLayout(columnWidths: widths, rowHeights: [], metrics: metrics)
        let heights = cells.map { row in
            TableGridLayout.rowHeight(textHeights: row.enumerated().map { column, cell in
                guard column < widths.count else { return 0 }
                let size = CGSize(width: CGFloat(columns.textWidth(column: column)), height: CGFloat.greatestFiniteMagnitude)
                return Double(cell.boundingRect(with: size, options: Self.measuring, context: nil).height.rounded(.up))
            }, lineHeight: lineHeight, metrics: metrics)
        }
        return Content(layout: TableGridLayout(columnWidths: widths, rowHeights: heights, metrics: metrics), cells: cells)
    }

    /// One line of body text: the height an empty cell still takes.
    private lazy var lineHeight: Double = {
        let sample = NSAttributedString(string: "Xg", attributes: theme.attributes(for: TextStyle()))
        let size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return Double(sample.boundingRect(with: size, options: Self.measuring, context: nil).height.rounded(.up))
    }()

    /// A cell's text as drawn: its inline styles in the editor's fonts and colours, syntax left out,
    /// aligned as its column says.
    private func attributed(_ content: Range<Int>, alignment: TableAlignment, text: MarkdownText, spans: [StyleSpan]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in TableCellText.runs(content, in: text, spans: spans, theme: notesTheme) {
            result.append(NSAttributedString(string: run.text, attributes: theme.attributes(for: run.style)))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        case .none: .natural
        }
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }
}
