import Foundation

/// The empty space under a page's last line, Notion-style, and the room typing keeps below the
/// caret. Without it the last line sits on the pane's bottom edge, and so does the caret while
/// writing at the end of a page. Lengths are points; y grows downward, as in the text view.
public enum NotesBottomSpace {
    /// The space's share of the pane's visible height: a little under half, like Notion's.
    public static let fraction = 0.4

    /// The space under the last line for a pane this tall.
    public static func height(visibleHeight: Double) -> Double {
        max(0, (visibleHeight * fraction).rounded())
    }

    /// The text view's height: its natural height (header, text and insets) plus the space, and
    /// never less than `minimum` (the pane itself, so a short page doesn't scroll at all).
    public static func documentHeight(natural: Double, visibleHeight: Double, minimum: Double) -> Double {
        max(minimum, natural + height(visibleHeight: visibleHeight))
    }

    /// What typing scrolls into view for the caret's rect (`minY` to `maxY`): the rect and the
    /// space below it, so the line being written stays above the bottom of the pane. Clamped to
    /// the document's end, and never taller than the pane, so the caret itself stays in view.
    public static func typingTarget(minY: Double, maxY: Double, visibleHeight: Double,
                                    documentHeight: Double) -> (minY: Double, maxY: Double) {
        let below = min(documentHeight, maxY + height(visibleHeight: visibleHeight), minY + visibleHeight)
        return (minY, max(maxY, below))
    }
}
