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
    /// the text container. Not the whole fragment: when the row is the last paragraph and
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
    /// The notes' body font (the editor theme's), so the title matches the text around it.
    var font: NSFont = NSFont.preferredFont(forTextStyle: .body)

    /// The row's title as drawn (live, not the label in the text).
    static func titleAttributes(font: NSFont, trashed: Bool) -> [NSAttributedString.Key: Any] {
        [ .font: font,
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
        // The icon: a document glyph at the text's size, in a slot a little wider than it, drawn at
        // its own aspect (a square rect squished it); a plain rounded rect if symbols are missing.
        let slot = CGRect(x: bounds.minX + 2, y: bounds.minY, width: (font.pointSize * 1.5).rounded(), height: bounds.height)
        if let symbol = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) {
            let image = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)) ?? symbol
            let size = image.size
            // A symbol drawn as is comes out black; tint a copy with the (resolved) label colour.
            let color: NSColor = row.isTrashed ? .tertiaryLabelColor : .secondaryLabelColor
            let tinted = NSImage(size: size, flipped: false) { rect in
                image.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: CGRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2,
                                   width: size.width, height: size.height))
        } else {
            NSColor.tertiaryLabelColor.setFill()
            let side = font.pointSize
            NSBezierPath(roundedRect: CGRect(x: slot.midX - side / 2, y: slot.midY - side / 2, width: side, height: side),
                         xRadius: 3, yRadius: 3).fill()
        }

        let title = NSAttributedString(string: row.title, attributes: Self.titleAttributes(font: font, trashed: row.isTrashed))
        // Centred on the row like the icon (drawing in the whole row's rect puts it at the top).
        let height = title.size().height
        let textRect = CGRect(x: slot.maxX + 6, y: bounds.midY - height / 2,
                              width: max(bounds.width - slot.width - 40, 0), height: height)
        title.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if row.isTrashed == false {
            let chevron = NSAttributedString(string: "›", attributes: Self.titleAttributes(font: font, trashed: false))
            let size = chevron.size()
            chevron.draw(at: CGPoint(x: bounds.maxX - size.width - 6, y: bounds.midY - size.height / 2))
        }
    }
}
