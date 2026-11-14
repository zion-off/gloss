import AppKit
import GlossAppModel
import GlossMarkdown
import GlossNotes

/// The notes text view: TextKit 2, plain-text buffer (the markdown source), everything visual
/// comes from the coordinator's derived attributes. Undo and input methods stay native because
/// the view owns the text while the user types.
@MainActor
final class NotesTextView: NSTextView {
    /// Offers a click to the coordinator: `true` when it took it (a task box toggled); `false`
    /// lets the click through.
    var onTextClick: ((Int) -> Bool)?
    /// A click on a subpage row (where the row is drawn, not where its hidden text is).
    var onRowClick: ((SubpageRow) -> Void)?
    /// The pointer moved over the text (hover previews); the point is in this view's coordinates.
    var onHover: ((NSPoint) -> Void)?
    /// The pointer left the text.
    var onHoverEnd: (() -> Void)?
    /// Keyboard focus came or went (enables the Format menu).
    var onFocusChange: ((Bool) -> Void)?
    /// A click or drag selection is in progress (the format bar waits for it to end).
    private(set) var isSelectingWithMouse = false
    /// The mouse button came up after a click or drag in the text.
    var onMouseSelectionEnd: (() -> Void)?
    /// A click on a drawn table's cell: the table's ordinal, the grid row (header first), the column.
    var onTableCellClick: ((Int, Int, Int) -> Void)?
    /// A "+" handle or the grid's menu: what to do, and to which table (its ordinal).
    var onTableCommand: ((TableCommand, Int) -> Void)? {
        get { tableTarget.perform }
        set { tableTarget.perform = newValue }
    }
    /// The drawn tables (the coordinator's), for cursor zones.
    var tableStore: TableGridStore?
    /// A paste of this plain text: `true` when the coordinator took it.
    var onPaste: ((String) -> Bool)?
    /// A divider dragged: the table's ordinal, its columns' new fractions, whether the drag ended.
    var onTableResize: ((Int, [Double], Bool) -> Void)?
    /// A double-click on a divider: that table back to automatic widths.
    var onTableResetWidths: ((Int) -> Void)?
    /// The view got wider or narrower (drawn tables fill the width).
    var onWidthChange: (() -> Void)?
    /// Light, dark or Increase Contrast changed (drawn tables resolve their colours with it).
    var onAppearanceChange: (() -> Void)?

    private var hoverArea: NSTrackingArea?
    private let tableTarget = TableActionTarget()
    private lazy var addRowHandle = makeHandle(.addRow)
    private lazy var addColumnHandle = makeHandle(.addColumn)
    /// The table whose handles show (its ordinal), and its rect in this view.
    private var handleTable: (ordinal: Int, rect: NSRect)?

    /// The subpage row under the pointer (this view's coordinates): Notion's soft rounded block.
    /// A view of its own beneath the text's: TextKit 2 renders layout fragments into
    /// their own cached layers, so a block painted in this view's `draw(_:)` was either covered or
    /// never repainted when the pointer moved.
    var hoverRowRect: NSRect? {
        didSet {
            guard hoverRowRect != oldValue else { return }
            guard let hoverRowRect else { rowHover.isHidden = true; return }
            if rowHover.superview !== self { addSubview(rowHover, positioned: .below, relativeTo: nil) }
            rowHover.frame = hoverRowRect
            rowHover.isHidden = false
            rowHover.needsDisplay = true
        }
    }
    private let rowHover = RowHoverBlock()

    /// The subpage row drawn under a point, and its block in this view's coordinates. By the row's
    /// drawn rect, not by character index: the line after a row (the extra line fragment at the
    /// end of the text shares the row's fragment) and the row's hidden text both map to indexes
    /// on the row's line.
    func rowHit(at point: NSPoint) -> (row: SubpageRow, rect: NSRect)? {
        guard let manager = textLayoutManager else { return nil }
        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = manager.textLayoutFragment(for: inContainer) as? SubpageRowFragment,
              let row = fragment.row else { return nil }
        let frame = fragment.layoutFragmentFrame
        let local = fragment.rowRect
        let rect = NSRect(x: origin.x + frame.minX + local.minX, y: origin.y + frame.minY + local.minY,
                          width: local.width, height: local.height)
        return rect.contains(point) ? (row, rect) : nil
    }

    /// A drawn table under a point: by the band its line's fragment draws, like subpage rows (the
    /// index under the point lands in hidden markdown that is laid out nothing like the grid).
    struct TableHit {
        let table: RenderedTable
        /// The table's top-left in this view's coordinates.
        let origin: NSPoint
        /// The point, from the table's top-left.
        let local: NSPoint

        var rect: NSRect { NSRect(x: origin.x, y: origin.y, width: CGFloat(table.layout.width), height: CGFloat(table.layout.height)) }
    }

    /// The cursor over a column divider.
    static var columnResizeCursor: NSCursor {
        if #available(macOS 15, *) { return .columnResize }
        return .resizeLeftRight
    }

    /// The column divider a table hit is on, if any.
    func divider(at hit: TableHit) -> Int? {
        guard case .divider(let divider)? = hit.table.layout.hit(x: Double(hit.local.x), y: Double(hit.local.y)) else { return nil }
        return divider
    }

    func tableHit(at point: NSPoint) -> TableHit? {
        guard let manager = textLayoutManager else { return nil }
        let container = textContainerOrigin
        let inContainer = NSPoint(x: point.x - container.x, y: point.y - container.y)
        guard let fragment = manager.textLayoutFragment(for: inContainer) as? TableGridFragment, let band = fragment.band else { return nil }
        let (origin, bandTop) = placement(of: fragment, band)
        // Not the empty last line TextKit may keep in the same fragment.
        guard point.y >= bandTop, point.y < bandTop + CGFloat(band.table.layout.lineHeights[band.line]) else { return nil }
        return TableHit(table: band.table, origin: origin, local: NSPoint(x: point.x - origin.x, y: point.y - origin.y))
    }

    /// Where a table line's fragment puts its table (top-left, this view's coordinates) and the band.
    private func placement(of fragment: NSTextLayoutFragment, _ band: (table: RenderedTable, line: Int, top: CGFloat)) -> (origin: NSPoint, bandTop: CGFloat) {
        let container = textContainerOrigin
        let frame = fragment.layoutFragmentFrame
        let bandTop = container.y + frame.minY + band.top
        return (NSPoint(x: container.x + frame.minX + band.table.originX, y: bandTop - CGFloat(band.table.layout.lineTops[band.line])), bandTop)
    }

    /// A drawn table's top-left in this view, if its first line is laid out (it is when on screen).
    func origin(of table: RenderedTable) -> NSPoint? {
        guard let manager = textLayoutManager, let content = textContentStorage, let first = table.lines.first,
              let location = content.location(content.documentRange.location, offsetBy: first.lowerBound),
              let fragment = manager.textLayoutFragment(for: location) as? TableGridFragment,
              fragment.state == .layoutAvailable, let band = fragment.band, band.table.ordinal == table.ordinal else { return nil }
        return placement(of: fragment, band).origin
    }

    // MARK: Cursor zones

    /// The text view's I-beam is a cursor rect over its visible area. Each drawn table on screen
    /// adds its zones inside it (arrow on the chrome, resize on dividers, I-beam in cells): AppKit
    /// lets cursor rects nest but not partly overlap, and the zones tile the grid. As cursor rects
    /// they are rebuilt with everything else after an edit or a scroll, so the cursor never flickers
    /// back to the I-beam until the next move.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let tables = tableStore?.all, !tables.isEmpty, let manager = textLayoutManager else { return }
        let visible = visibleRect
        let container = textContainerOrigin
        manager.ensureLayout(for: visible.offsetBy(dx: -container.x, dy: -container.y))
        for table in tables {
            guard let origin = origin(of: table) else { continue }
            for zone in table.layout.cursorZones() {
                let rect = NSRect(x: origin.x + CGFloat(zone.rect.x), y: origin.y + CGFloat(zone.rect.y),
                                  width: CGFloat(zone.rect.width), height: CGFloat(zone.rect.height)).intersection(visible)
                guard !rect.isEmpty else { continue }
                let cursor: NSCursor = switch zone.cursor {
                case .arrow: .arrow
                case .text: .iBeam
                case .columnResize: Self.columnResizeCursor
                }
                addCursorRect(rect, cursor: cursor)
            }
        }
    }

    private func makeHandle(_ command: TableCommand) -> TableHandle {
        let handle = TableHandle(command: command)
        handle.onPress = { [weak self] in
            guard let self, let ordinal = self.handleTable?.ordinal else { return }
            self.onTableCommand?(command, ordinal)
        }
        return handle
    }

    /// Shows the "+" handles on a drawn table's bottom and right edges, like Notes. Subviews, not
    /// drawn by the fragments: a fragment's rendering is cached and doesn't repaint on hover.
    /// They fade in (0.12 s) when they appear, and move without a fade when the table moves.
    func showTableHandles(for hit: TableHit) {
        let layout = hit.table.layout
        let appearing = handleTable == nil
        let slop = CGFloat(layout.metrics.handleSlop)
        let pointer = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        for (handle, rect) in [(addRowHandle, layout.addRowHandle), (addColumnHandle, layout.addColumnHandle)] {
            if handle.superview !== self { addSubview(handle) }
            let frame = NSRect(x: hit.origin.x + CGFloat(rect.x), y: hit.origin.y + CGFloat(rect.y),
                               width: CGFloat(rect.width), height: CGFloat(rect.height)).insetBy(dx: -slop, dy: -slop)
            if handle.frame != frame || appearing {
                handle.frame = frame
                handle.circleInset = slop
                handle.resetHover(pointerInside: pointer.map { frame.contains($0) } ?? false)
            }
            if appearing {
                handle.alphaValue = 0
                handle.isHidden = false
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    handle.animator().alphaValue = 1
                }
            }
        }
        handleTable = (hit.table.ordinal, hit.rect)
    }

    /// Hides the handles at once (after an action, an edit, a scroll, the pointer leaving).
    func hideTableHandles() {
        guard handleTable != nil else { return }
        for handle in [addRowHandle, addColumnHandle] {
            handle.isHidden = true
            handle.resetHover(pointerInside: false)
        }
        handleTable = nil
    }

    /// Whether the pointer is still where the shown handles belong: over their table or them.
    func isNearTableHandles(_ point: NSPoint) -> Bool {
        guard let handleTable else { return false }
        let metrics = TableGridMetrics.standard
        let reach = CGFloat(metrics.handleSize / 2 + metrics.handleSlop)
        return handleTable.rect.insetBy(dx: -reach, dy: -reach).contains(point)
    }

    /// The grid's context menu: its own commands only (a text menu would act on hidden markdown).
    private func tableMenu(for ordinal: Int) -> NSMenu {
        let menu = NSMenu(title: "table")
        for command in [TableCommand.addRow, .addColumn] {
            let item = NSMenuItem(title: command.title, action: #selector(TableActionTarget.menuItem(_:)), keyEquivalent: "")
            item.target = tableTarget
            item.representedObject = TableActionTarget.Choice(command: command, ordinal: ordinal)
            menu.addItem(item)
        }
        return menu
    }

    /// Right-clicks on a grid show its menu here, before the text view's own handling could move
    /// the caret into the table (which would turn the grid back into markdown under the menu).
    override func rightMouseDown(with event: NSEvent) {
        if let hit = tableHit(at: convert(event.locationInWindow, from: nil)) {
            NSMenu.popUpContextMenu(tableMenu(for: hit.table.ordinal), with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let hit = tableHit(at: convert(event.locationInWindow, from: nil)) { return tableMenu(for: hit.table.ordinal) }
        return super.menu(for: event)
    }

    override func paste(_ sender: Any?) {
        if let string = NSPasteboard.general.string(forType: .string), onPaste?(string) == true { return }
        super.paste(sender)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // One area over the visible rect: the pointer's position anywhere over the text.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        // Tracking areas go by geometry, not by what's on top: moves over the format bar or the
        // slash menu still land here. The view on top owns the pointer there, so this view
        // shows no hover and leaves the cursor alone, as if the pointer had left.
        guard isUnderPointer(event) else { onHoverEnd?(); return }
        onHover?(convert(event.locationInWindow, from: nil))
    }

    /// Whether this view is what a click at the event's location would hit, the same hit test
    /// the window runs for clicks (from the frame view, in window coordinates).
    private func isUnderPointer(_ event: NSEvent) -> Bool {
        guard let content = window?.contentView else { return true }
        let root = content.superview ?? content
        guard let hit = root.hitTest(event.locationInWindow) else { return false }
        return hit.isDescendant(of: self)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverEnd?()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    /// `characterIndexForInsertion(at:)` takes view coordinates and is the documented call for
    /// clicks; `characterIndex(for:)` wants screen coordinates and serves input methods.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = rowHit(at: point), let onRowClick {
            onRowClick(hit.row)
            return
        }
        if let hit = tableHit(at: point) {
            if event.modifierFlags.contains(.control) {
                NSMenu.popUpContextMenu(tableMenu(for: hit.table.ordinal), with: event, for: self)
                return
            }
            if let divider = divider(at: hit) {
                if event.clickCount >= 2 { onTableResetWidths?(hit.table.ordinal) } else { trackDividerDrag(divider, of: hit, from: point) }
                return
            }
            // A drawn cell isn't edited in place: the click puts the caret in the cell's markdown,
            // and the table shows as text until the caret leaves it.
            let cell = hit.table.layout.nearestCell(x: Double(hit.local.x), y: Double(hit.local.y))
            onTableCellClick?(hit.table.ordinal, cell.row, cell.column)
            return
        }
        // Only over a line: below the last one the insertion index is the end of the text, and a
        // subpage row or task box there would answer clicks on empty space.
        if isOverText(point) {
            let index = characterIndexForInsertion(at: point)
            if index != NSNotFound, let onTextClick, onTextClick(index) { return }
        }
        // The text view tracks a click or drag selection inside `mouseDown` until the button
        // comes up.
        isSelectingWithMouse = true
        super.mouseDown(with: event)
        isSelectingWithMouse = false
        onMouseSelectionEnd?()
    }

    /// Follows a divider drag until the button comes up: the two columns beside it trade width
    /// as the pointer moves. Nothing changes until it does move, so the first click of a
    /// double-click (a reset) stores nothing.
    private func trackDividerDrag(_ divider: Int, of hit: TableHit, from start: NSPoint) {
        let widths = hit.table.layout.columnWidths
        let minimum = hit.table.layout.metrics.minimumColumnWidth
        var moved = false
        Self.columnResizeCursor.set()
        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let x = convert(event.locationInWindow, from: nil).x
            let done = event.type == .leftMouseUp
            moved = moved || x != start.x
            if moved {
                let resized = TableWidths.resizing(widths, divider: divider, by: Double(x - start.x), minimum: minimum)
                onTableResize?(hit.table.ordinal, TableWidths.fractions(of: resized), done)
            }
            if done { break }
            Self.columnResizeCursor.set()
        }
    }

    /// Whether a point (this view's coordinates) is on a laid-out line rather than empty space.
    func isOverText(_ point: NSPoint) -> Bool {
        guard let manager = textLayoutManager else { return true }
        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = manager.textLayoutFragment(for: inContainer) else { return false }
        // Vertical only: a fragment's frame is as wide as its text, and a row under hidden markdown
        // is far narrower than the line it fills.
        return inContainer.y >= fragment.layoutFragmentFrame.minY && inContainer.y < fragment.layoutFragmentFrame.maxY
    }
}

/// Receives the grid's menu choices: a plain object, so the text view's own menu validation
/// never sees (and disables) actions it doesn't know.
@MainActor
private final class TableActionTarget: NSObject {
    struct Choice {
        let command: TableCommand
        let ordinal: Int
    }

    var perform: ((TableCommand, Int) -> Void)?

    @objc func menuItem(_ sender: NSMenuItem) {
        if let choice = sender.representedObject as? Choice { perform?(choice.command, choice.ordinal) }
    }
}

/// The hover block behind a subpage row: a rounded fill in a translucent system colour, so it
/// reads the same under the row's icon and title (or over them, if TextKit ever draws the text
/// beneath its subviews). Never takes the mouse.
@MainActor
private final class RowHoverBlock: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
