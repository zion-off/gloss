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

    private var hoverArea: NSTrackingArea?

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
        // Only over a line: below the last one the insertion index is the end of the text, and a
        // subpage row or task box there would answer clicks on empty space.
        if isOverText(point) {
            let index = characterIndexForInsertion(at: point)
            if index != NSNotFound, let onTextClick, onTextClick(index) { return }
        }
        super.mouseDown(with: event)
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
