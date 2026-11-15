import Foundation

/// The notes' line heights, Notion's: body text and code blocks at 1.5 times their size,
/// headings at 1.3. A line takes its height from its block, not from whichever run starts it:
/// inline code (smaller, monospaced) in a paragraph rides on the paragraph's line.
///
/// The text system puts a tall line's extra room above its text rather than splitting it as CSS
/// does; between lines that reads the same. (Splitting it didn't work in TextKit 2: a baseline
/// offset shortened the lines by the offset, and line spacing lands above the next line anyway;
/// a probe measured both.)
public enum NotesTypography {
    public static func lineHeightMultiple(for role: TextStyle.FontRole) -> Double {
        switch role {
        case .heading: 1.3
        case .body, .monospaced: 1.5
        }
    }

    /// The role whose size sets the line a run sits on.
    public static func lineRole(for style: TextStyle) -> TextStyle.FontRole {
        let role = style.font ?? .body
        if role == .monospaced, style.block != .code { return .body }
        return role
    }

    /// A line's height for its role's font size, in whole points.
    public static func lineHeight(for role: TextStyle.FontRole, fontSize: Double) -> Double {
        (fontSize * lineHeightMultiple(for: role)).rounded()
    }
}
