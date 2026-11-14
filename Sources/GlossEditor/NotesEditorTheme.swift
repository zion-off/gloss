import AppKit
import GlossNotes

/// Maps the editor's semantic `TextStyle`s onto the system font and colours, so light/dark mode
/// and Increase Contrast come from the system rather than our own palette. The
/// buffer is the raw markdown; these attributes are presentation only and never saved.
///
/// A class: `baseFont` caches the system fonts it resolves.
@MainActor final class NotesEditorTheme {
    /// Resolved fonts per role, before bold/italic traits.
    private var fonts: [TextStyle.FontRole: NSFont] = [:]

    init() {}

    /// A subpage row's height, Notion-like: a body line with room around the icon.
    static let rowHeight: CGFloat = 30

    /// Notion's type scale: 16 pt body, headings at 30, 24 and 20, code a little smaller than
    /// the text around it. The system's own text styles (13 pt body) read small for writing in.
    private static func size(_ spec: TextStyle.FontRole) -> CGFloat {
        switch spec {
        case .body: NotesEditorMetrics.bodySize
        case .heading(1): 30
        case .heading(2): 24
        case .heading(3): 20
        case .heading: NotesEditorMetrics.bodySize
        case .monospaced: 14
        }
    }

    func baseFont(_ spec: TextStyle.FontRole) -> NSFont {
        if let cached = fonts[spec] { return cached }
        let font = switch spec {
        case .monospaced: NSFont.monospacedSystemFont(ofSize: Self.size(spec), weight: .regular)
        case .body, .heading: NSFont.systemFont(ofSize: Self.size(spec))
        }
        fonts[spec] = font
        return font
    }

    /// The attributes a run draws with (everything the style sets, nothing else).
    func attributes(for style: TextStyle) -> [NSAttributedString.Key: Any] {
        // Every run sets its colour: `setAttributes` replaces the whole attribute set, and an
        // attributed string with no foreground colour draws black, which vanishes in dark mode.
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor]
        var font = baseFont(style.font ?? .body)
        if style.bold == true { font = Self.withTraits(font, .bold) }
        if style.italic == true { font = Self.withTraits(font, .italic) }
        // Always a font: a run without one draws in the text system's default (Helvetica 12),
        // which is why plain notes text and a subpage row's title (body font) differed in size.
        attributes[.font] = font

        switch style.color {
        case .text?: break
        case .secondary?: attributes[.foregroundColor] = NSColor.secondaryLabelColor
        case .tertiary?: attributes[.foregroundColor] = NSColor.tertiaryLabelColor
        // Links are muted, not blue (Notion's): grey that follows light and dark mode.
        case .link?: attributes[.foregroundColor] = NSColor.secondaryLabelColor
        case .accent?: attributes[.foregroundColor] = NSColor.controlAccentColor
        case .warning?: attributes[.foregroundColor] = NSColor.systemRed
        case nil: break
        }

        if style.strikethrough == true { attributes[.strikethroughStyle] = NSNumber(value: NSUnderlineStyle.single.rawValue) }
        switch style.underline {
        case .single?: attributes[.underlineStyle] = NSNumber(value: NSUnderlineStyle.single.rawValue)
        case .dotted?: attributes[.underlineStyle] = NSNumber(value: NSUnderlineStyle.single.union(.patternDot).rawValue)
        case .subtle?:
            attributes[.underlineStyle] = NSNumber(value: NSUnderlineStyle.single.rawValue)
            attributes[.underlineColor] = NSColor.tertiaryLabelColor
        case nil: break
        }

        if style.block == .quote {
            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent = 18
            paragraph.firstLineHeadIndent = 18
            attributes[.paragraphStyle] = paragraph
        }
        if style.block == .row {
            // A subpage row's line: always one row tall, never wrapped by its hidden markdown, so
            // the row drawn over it and the line after it sit where the layout says.
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = Self.rowHeight
            paragraph.maximumLineHeight = Self.rowHeight
            paragraph.lineBreakMode = .byClipping
            attributes[.paragraphStyle] = paragraph
        }
        if style.block == .table {
            // A drawn table's line: never wrapped by its hidden markdown; the coordinator gives
            // it its band's height (`tableLineStyle`), which depends on the grid's layout.
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            attributes[.paragraphStyle] = paragraph
        }
        if style.hidden == true { attributes[.foregroundColor] = NSColor.clear }
        if style.collapsed == true {
            // No glyph and no width, yet still characters: the caret and selection keep working,
            // and the cursor touching the element swaps this for the revealed style.
            attributes[.foregroundColor] = NSColor.clear
            attributes[.font] = NSFont.systemFont(ofSize: 0.1)
        }
        return attributes
    }

    /// A drawn table line's paragraph style: exactly `height` tall (its band of the grid), never wrapping.
    func tableLineStyle(height: CGFloat) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        paragraph.lineBreakMode = .byClipping
        return paragraph
    }

    /// `NSFontDescriptor.withSymbolicTraits` returns a new descriptor (not optional); the font
    /// from it is failable in principle.
    static func withTraits(_ font: NSFont, _ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
