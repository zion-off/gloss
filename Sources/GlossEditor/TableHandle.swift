import AppKit

/// What the grid's "+" handles and context menu ask for.
enum TableCommand: Sendable {
    case addRow, addColumn

    var title: String {
        switch self {
        case .addRow: "add row"
        case .addColumn: "add column"
        }
    }
}

/// A small round "+" button on a drawn table's edge (Notes' handles): the system's control
/// background and separator, a plus in the secondary label colour, the arrow cursor. It never
/// takes keyboard focus, so a click leaves the caret and selection in the text.
@MainActor final class TableHandle: NSButton {
    private var cursorArea: NSTrackingArea?

    convenience init(command: TableCommand, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: command.title)
        image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)) ?? symbol
        title = ""
        imagePosition = .imageOnly
        self.target = target
        self.action = action
        isBordered = false
        refusesFirstResponder = true
        contentTintColor = .secondaryLabelColor
        toolTip = command.title
        setAccessibilityLabel(command.title)
        isHidden = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor.controlBackgroundColor.setFill()
        circle.fill()
        NSColor.separatorColor.setStroke()
        circle.lineWidth = 1
        circle.stroke()
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorArea { removeTrackingArea(cursorArea) }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorArea = area
    }

    /// The arrow, as over any button (the text view's I-beam would show through otherwise).
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}
