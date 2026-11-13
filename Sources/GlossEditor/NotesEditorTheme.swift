#if os(macOS)
import AppKit
import GlossNotes

/// Maps the editor's semantic `TextStyle`s onto system fonts and colours, so light/dark mode,
/// Increase Contrast and Dynamic Type come from the system rather than our own palette. The
/// buffer is the raw markdown; these attributes are presentation only and never saved.
@MainActor struct NotesEditorTheme {
    /// The font a run draws with, before bold/italic traits.
    enum FontSpec: Hashable {
        case body
        case heading(Int)
        case monospaced
    }

    private var fonts: [FontSpec: NSFont] = [:]

    func baseFont(_ spec: FontSpec) -> NSFont {
        if let cached = fonts[spec] { return cached }
        let font: NSFont
        switch spec {
        case .body: font = NSFont.preferredFont(forTextStyle: .body)
        case .heading(let level):
            let style: NSFont.TextStyle = switch level {
            case 1: .title1
            case 2: .title2
            case 3: .title3
            default: .headline
            }
            font = NSFont.preferredFont(forTextStyle: style)
        case .monospaced: font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        }
        fonts[spec] = font
        return font
    }

    /// The attributes a run draws with (everything the style sets, nothing else).
    func attributes(for style: TextStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        var font = baseFont(style.font ?? .body)
        if style.bold == true { font = Self.withTraits(font, .bold) }
        if style.italic == true { font = Self.withTraits(font, .italic) }
        if style.font != nil || style.bold != nil || style.italic != nil { attributes[.font] = font }

        switch style.color {
        case .text?: break
        case .secondary?: attributes[.foregroundColor] = NSColor.secondaryLabelColor
        case .tertiary?: attributes[.foregroundColor] = NSColor.tertiaryLabelColor
        case .link?: attributes[.foregroundColor] = NSColor.linkColor
        case .accent?: attributes[.foregroundColor] = NSColor.controlAccentColor
        case .warning?: attributes[.foregroundColor] = NSColor.systemRed
        case nil: break
        }

        if style.strikethrough == true { attributes[.strikethroughStyle] = NSNumber(value: NSUnderlineStyle.single.rawValue) }
        switch style.underline {
        case .single?: attributes[.underlineStyle] = NSNumber(value: NSUnderlineStyle.single.rawValue)
        case .dotted?: attributes[.underlineStyle] = NSNumber(value: [NSUnderlineStyle.single, NSUnderlineStyle.patternDot].rawValue)
        case nil: break
        }

        if style.block == .quote {
            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent = 18
            paragraph.firstLineHeadIndent = 18
            attributes[.paragraphStyle] = paragraph
        }
        if style.hidden == true { attributes[.foregroundColor] = NSColor.clear }
        return attributes
    }

    /// `NSFontDescriptor.withSymbolicTraits` returns a new descriptor (not optional); the font
    /// from it is failable in principle.
    static func withTraits(_ font: NSFont, _ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
#endif
