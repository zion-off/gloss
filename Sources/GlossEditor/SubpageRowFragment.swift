#if os(macOS)
import AppKit
import GlossNotes

/// Draws a subpage block line as a row (icon + live title) instead of its raw markdown. The
/// text itself is hidden (the theme's `hidden` style), and this fragment replaces the default
/// text drawing entirely. Not main-actor isolated: neither is `NSTextLayoutFragment`, whose
/// `draw(at:in:)` this overrides.
final class SubpageRowFragment: NSTextLayoutFragment {
    /// The row spans the whole fragment, not just the (hidden) text's width: TextKit clips drawing
    /// to this rect, in the fragment's own coordinates.
    override var renderingSurfaceBounds: CGRect {
        CGRect(origin: .zero, size: layoutFragmentFrame.size)
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
        let bounds = CGRect(origin: point, size: layoutFragmentFrame.size)

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
        let textRect = CGRect(x: iconRect.maxX + 6, y: bounds.minY, width: max(bounds.width - iconRect.width - 16, 0),
                              height: bounds.height)
        title.draw(in: textRect)
        if row.isTrashed == false {
            let chevron = NSAttributedString(string: "›", attributes: Self.titleAttributes(trashed: false))
            let size = chevron.size()
            chevron.draw(at: CGPoint(x: bounds.maxX - size.width - 6, y: bounds.midY - size.height / 2))
        }
    }
}
#endif
