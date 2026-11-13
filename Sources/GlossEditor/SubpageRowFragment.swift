#if os(macOS)
import AppKit
import GlossCore
import GlossNotes

/// Draws a subpage block line as a row (icon + live title) instead of its raw markdown. The
/// text itself is hidden (the theme's `hidden` style), and this fragment replaces the default
/// text drawing entirely. Not main-actor isolated: neither is `NSTextLayoutFragment`, whose
/// `draw(at:in:)` this overrides.
final class SubpageRowFragment: NSTextLayoutFragment {
    /// The whole width and the whole fragment, not just the (hidden) text's: TextKit clips drawing
    /// to this rect, in the fragment's own coordinates.
    override var renderingSurfaceBounds: CGRect {
        let row = rowRect
        return CGRect(x: 0, y: 0, width: row.width, height: max(layoutFragmentFrame.height, row.maxY))
    }

    /// Where the row is, in the fragment's own coordinates: the paragraph's first line, as wide as
    /// the text container. Not the whole fragment (D-146): when the row is the last paragraph and
    /// the text ends with its newline, TextKit 2 puts the empty last line (the extra line fragment)
    /// in this same fragment, and a row centred on both lines slid down over the new line, and
    /// answered clicks there.
    var rowRect: CGRect {
        let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
        guard let line = textLineFragments.first?.typographicBounds else {
            return CGRect(x: 0, y: 0, width: width, height: layoutFragmentFrame.height)
        }
        return CGRect(x: 0, y: line.minY, width: width, height: line.height)
    }

    var row: SubpageRow?
    /// The text view's appearance when the fragment was made (light, dark, high contrast).
    var appearance: NSAppearance?

    /// The row's title as drawn (live, not the label in the text).
    static func titleAttributes(trashed: Bool) -> [NSAttributedString.Key: Any] {
        [ .font: NSFont.preferredFont(forTextStyle: .body),
          .foregroundColor: trashed ? NSColor.tertiaryLabelColor : NSColor.labelColor,
          .strikethroughStyle: NSNumber(value: trashed ? NSUnderlineStyle.single.rawValue : 0) ]
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        guard let row else { return super.draw(at: point, in: context) }
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            drawRow(row, at: point)
        }
    }

    private func drawRow(_ row: SubpageRow, at point: CGPoint) {
        // `point` is already where this fragment's origin lands in the context: adding the
        // frame's own origin on top pushed the row down by the paragraph's offset in the page,
        // out of the clip, so every row but one at the very top was invisible.
        let bounds = rowRect.offsetBy(dx: point.x, dy: point.y)

        // The hover block is the text view's (`NotesTextView.hoverRowRect`, a view of its own): a
        // fragment's rendering is cached and doesn't repaint when the pointer moves.
        // The icon: a document glyph; a plain rounded rect if symbols are unavailable.
        let iconRect = CGRect(x: bounds.minX + 2, y: bounds.midY - 8, width: 16, height: 16)
        if let image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) {
            // A symbol drawn as is comes out black; tint a copy with the (resolved) label colour.
            let color: NSColor = row.isTrashed ? .tertiaryLabelColor : .secondaryLabelColor
            let tinted = NSImage(size: iconRect.size, flipped: false) { rect in
                image.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: iconRect)
        } else {
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: iconRect, xRadius: 3, yRadius: 3).fill()
        }

        let title = NSAttributedString(string: row.title, attributes: Self.titleAttributes(trashed: row.isTrashed))
        // Centred on the row like the icon (drawing in the whole row's rect puts it at the top).
        let height = title.size().height
        let textRect = CGRect(x: iconRect.maxX + 6, y: bounds.midY - height / 2,
                              width: max(bounds.width - iconRect.width - 40, 0), height: height)
        title.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if row.isTrashed == false {
            let chevron = NSAttributedString(string: "›", attributes: Self.titleAttributes(trashed: false))
            let size = chevron.size()
            chevron.draw(at: CGPoint(x: bounds.maxX - size.width - 6, y: bounds.midY - size.height / 2))
        }
    }
}
#endif
