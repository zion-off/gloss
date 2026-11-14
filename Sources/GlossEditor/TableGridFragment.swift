import AppKit
import GlossNotes

/// One table drawn as a grid: where its lines are in the text and what they draw. Immutable, so
/// layout fragments may read it whenever TextKit draws them.
final class RenderedTable: @unchecked Sendable {
    /// Its position among the page's tables.
    let ordinal: Int
    /// Its source lines, without line breaks: header, delimiter, body rows.
    let lines: [Range<Int>]
    let layout: TableGridLayout
    /// The grid rows' cells (header first), styled and aligned.
    let cells: [[NSAttributedString]]
    /// The grid's left edge in its lines' fragments: where the text starts (the container's
    /// line fragment padding), so the border lines up with the text around it.
    let originX: CGFloat

    init(ordinal: Int, lines: [Range<Int>], layout: TableGridLayout, cells: [[NSAttributedString]], originX: CGFloat) {
        self.ordinal = ordinal
        self.lines = lines
        self.layout = layout
        self.cells = cells
        self.originX = originX
    }

    var range: Range<Int> { (lines.first?.lowerBound ?? 0)..<(lines.last?.upperBound ?? 0) }

    /// Whether the two draw the same grid (wherever they sit in the text).
    func drawsSame(as other: RenderedTable) -> Bool {
        layout == other.layout && originX == other.originX && cells == other.cells
    }
}

/// The drawn tables, shared by the editor, which replaces them whenever it restyles, and the
/// layout fragments that draw them. A fragment looks its table up each time it lays out or draws
/// instead of keeping one, so a fragment TextKit keeps around never draws an old grid.
final class TableGridStore: @unchecked Sendable {
    private let lock = NSLock()
    private var tables: [RenderedTable] = []
    private var drawingAppearance: NSAppearance?

    func replace(_ tables: [RenderedTable], appearance: NSAppearance?) {
        lock.lock()
        defer { lock.unlock() }
        self.tables = tables
        drawingAppearance = appearance
    }

    var all: [RenderedTable] {
        lock.lock()
        defer { lock.unlock() }
        return tables
    }

    /// The text view's appearance: dynamic colours resolve against the drawing appearance, which
    /// isn't the view's while a fragment draws (see `SubpageRowFragment`).
    var appearance: NSAppearance? {
        lock.lock()
        defer { lock.unlock() }
        return drawingAppearance
    }

    /// The drawn table and line a paragraph is. Matched by overlap, like subpage rows: TextKit
    /// may or may not count the line break into the paragraph's range.
    func line(covering paragraph: Range<Int>) -> (table: RenderedTable, line: Int)? {
        for table in all {
            if let line = table.lines.firstIndex(where: { $0.overlaps(paragraph) }) { return (table, line) }
        }
        return nil
    }
}

/// A drawn table's source line: draws its band of the grid in place of its markdown, which stays
/// in the text, hidden (the theme's `hidden` style). Each band strokes the whole grid clipped to
/// itself, so neighbouring bands join without seams and the rounded corners land in the first and
/// last bands. Not main-actor isolated: neither is `NSTextLayoutFragment`.
final class TableGridFragment: NSTextLayoutFragment {
    var store: TableGridStore?

    /// This fragment's table and line, and the top of its band in the fragment's coordinates:
    /// the paragraph's first line. Not the whole fragment: when the table ends the text and a line
    /// break follows it, TextKit puts the empty last line in this same fragment (the subpage rows
    /// slid over it).
    var band: (table: RenderedTable, line: Int, top: CGFloat)? {
        guard let store, let manager = textLayoutManager, let element = textElement,
              let paragraph = NotesEditorCoordinator.offsets(of: element, in: manager),
              let found = store.line(covering: paragraph), found.line < found.table.layout.lineHeights.count else { return nil }
        return (found.table, found.line, textLineFragments.first?.typographicBounds.minY ?? 0)
    }

    override var renderingSurfaceBounds: CGRect {
        guard let band else { return super.renderingSurfaceBounds }
        let height = CGFloat(band.table.layout.lineHeights[band.line])
        let width = band.table.originX + CGFloat(band.table.layout.width) + 1
        return CGRect(x: 0, y: min(0, band.top), width: max(width, layoutFragmentFrame.width),
                      height: max(layoutFragmentFrame.height, band.top + height))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        guard let band, let store else { return super.draw(at: point, in: context) }
        (store.appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            Self.draw(line: band.line, of: band.table, left: point.x, top: point.y + band.top)
        }
    }

    /// Draws line `line`'s band of `table` with the band's top-left at (`left`, `top`).
    private static func draw(line: Int, of table: RenderedTable, left: CGFloat, top: CGFloat) {
        let layout = table.layout
        let originX = left + table.originX
        let originY = top - CGFloat(layout.lineTops[line])
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath.clip(CGRect(x: left, y: top, width: table.originX + CGFloat(layout.width) + 1,
                                 height: CGFloat(layout.lineHeights[line])))

        let grid = CGRect(x: originX, y: originY + CGFloat(layout.gridTop), width: CGFloat(layout.width),
                          height: CGFloat(layout.gridBottom - layout.gridTop))
        NSColor.separatorColor.setStroke()
        let radius = CGFloat(layout.metrics.cornerRadius)
        let border = NSBezierPath(roundedRect: grid.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
        // Hairlines on the pixel grid: half a point off a whole point.
        let rules = NSBezierPath()
        rules.lineWidth = 1
        for edge in layout.columnEdges.dropFirst().dropLast() {
            let x = (originX + CGFloat(edge)).rounded(.down) + 0.5
            rules.move(to: NSPoint(x: x, y: grid.minY))
            rules.line(to: NSPoint(x: x, y: grid.maxY))
        }
        for rule in layout.rowRules {
            let y = (originY + CGFloat(rule)).rounded(.down) + 0.5
            rules.move(to: NSPoint(x: grid.minX, y: y))
            rules.line(to: NSPoint(x: grid.maxX, y: y))
        }
        rules.stroke()

        guard let row = TableGridLayout.gridRow(ofLine: line), table.cells.indices.contains(row) else { return }
        for (column, cell) in table.cells[row].enumerated() where column < layout.columnWidths.count {
            let frame = layout.textFrame(row: row, column: column)
            cell.draw(with: CGRect(x: originX + CGFloat(frame.x), y: originY + CGFloat(frame.y),
                                   width: CGFloat(frame.width), height: CGFloat(frame.height) + 1),
                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }
}
