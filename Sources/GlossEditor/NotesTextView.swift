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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndex(for: point)
        if index != NSNotFound, let onTextClick, onTextClick(index) { return }
        super.mouseDown(with: event)
    }
}
#endif
