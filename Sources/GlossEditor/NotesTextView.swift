#if os(macOS)
import AppKit
import GlossAppModel
import GlossMarkdown
import GlossNotes

/// The notes text view: TextKit 2, plain-text buffer (the markdown source), everything visual
/// comes from the coordinator's derived attributes. Undo and input methods stay native because
/// the view owns the text while the user types.
@MainActor
final class NotesTextView: NSTextView {
    /// Offers a click to the coordinator: `true` when it took it (a task box toggled, a
    /// subpage row opened); `false` lets the click through.
    var onTextClick: ((Int) -> Bool)?
    /// The pointer moved over the text (hover previews); the point is in this view's coordinates.
    var onHover: ((NSPoint) -> Void)?
    /// The pointer left the text.
    var onHoverEnd: (() -> Void)?
    /// Keyboard focus came or went (enables the Format menu).
    var onFocusChange: ((Bool) -> Void)?

    private var hoverArea: NSTrackingArea?

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
        onHover?(convert(event.locationInWindow, from: nil))
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
    /// clicks; `characterIndex(for:)` wants screen coordinates and serves input methods (review 6).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
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
#endif
