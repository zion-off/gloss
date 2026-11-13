#if os(macOS)
import AppKit
import GlossNotes

/// Draws a subpage block line as a row (icon + live title) instead of its raw markdown. The
/// text itself is hidden (the theme's `hidden` style), and this fragment replaces the default
/// text drawing entirely.
@MainActor
final class SubpageRowFragment: NSTextLayoutFragment {
    var row: SubpageRow?

    /// The row's title as drawn (live, not the label in the text).
    static func titleAttributes(trashed: Bool) -> [NSAttributedString.Key: Any] {
        [ .font: NSFont.preferredFont(forTextStyle: .body),
          .foregroundColor: trashed ? NSColor.tertiaryLabelColor : NSColor.labelColor,
          .strikethroughStyle: NSNumber(value: trashed ? NSUnderlineStyle.single.rawValue : 0) ]
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        guard let row else { return super.draw(at: point, in: context) }
        let frame = layoutFragmentFrame
        let origin = CGPoint(x: point.x + frame.origin.x, y: point.y + frame.origin.y)
        let bounds = CGRect(origin: origin, size: frame.size)

        // The icon: a document glyph; a plain rounded rect if symbols are unavailable.
        let iconRect = CGRect(x: bounds.minX + 2, y: bounds.midY - 8, width: 16, height: 16)
        if let image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) {
            image.draw(in: iconRect)
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
            let size = chevron.size
            chevron.draw(at: CGPoint(x: bounds.maxX - size.width - 6, y: bounds.midY - size.height / 2))
        }
    }
}
#endif
