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

/// A small round "+" on a drawn table's edge, like Notes' handles. It behaves like the format
/// bar's buttons: a rounded fill in the subpage rows' hover colour fades in under the pointer
/// (0.12 s) and deepens while pressed, the whole frame (a little more than the drawn circle) takes
/// the click, and the arrow cursor shows over it. It never takes keyboard focus, so a click leaves
/// the caret and selection in the text. A view of its own rather than an `NSButton`, so the
/// hover fill sits under the glyph instead of over it.
@MainActor final class TableHandle: NSView {
    var onPress: (() -> Void)?
    private let command: TableCommand
    private let fill = HandleFill()
    private let glyph = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false { didSet { updateFill(animated: false) } }

    init(command: TableCommand) {
        self.command = command
        super.init(frame: .zero)
        toolTip = command.title
        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        // Sized and weighted to sit in the circle like the format bar's glyphs sit in their cells.
        glyph.image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)) ?? symbol
        glyph.contentTintColor = .secondaryLabelColor
        glyph.setAccessibilityElement(false)
        fill.alphaValue = 0
        addSubview(fill)
        addSubview(glyph)
        isHidden = true
    }

    /// Every click inside the frame is the handle's, glyph included (the image view would take it).
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    required init?(coder: NSCoder) { nil }

    /// The drawn circle inside the frame; the rest of the frame is click target.
    var circleInset: CGFloat = 3 {
        didSet { needsLayout = true }
    }

    private var circle: NSRect { bounds.insetBy(dx: circleInset, dy: circleInset) }

    override func layout() {
        super.layout()
        fill.frame = circle
        glyph.frame = circle
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: Hover and press

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true, animated: true) }
    override func mouseExited(with event: NSEvent) { setHovered(false, animated: true) }

    /// The arrow, as over any button (the text view's I-beam would show through otherwise).
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    /// Sets the hover state without a fade: after the handle moves (its table changed under the
    /// pointer) or hides, the old state must not linger, nor fade in where the pointer already is.
    func resetHover(pointerInside: Bool) {
        setHovered(pointerInside, animated: false)
    }

    private func setHovered(_ hovered: Bool, animated: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateFill(animated: animated)
    }

    private func updateFill(animated: Bool) {
        fill.color = isPressed ? .tertiaryLabelColor : .quaternaryLabelColor
        let alpha: CGFloat = isHovered || isPressed ? 1 : 0
        guard animated else { fill.alphaValue = alpha; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            fill.animator().alphaValue = alpha
        }
    }

    /// Tracks the press until the button comes up: pressed while the pointer is inside, and a
    /// press only if it comes up inside, like any button.
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { break }
            isPressed = inside
        }
        isPressed = false
        guard inside else { return }
        // The action changes the table under the pointer: the hover goes at once.
        resetHover(pointerInside: false)
        onPress?()
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { command.title }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// The handle's hover and press fill, under its glyph. Never takes the mouse.
@MainActor private final class HandleFill: NSView {
    var color: NSColor = .quaternaryLabelColor {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
