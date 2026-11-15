import Foundation
import GlossCore
import GlossReaderBridge

/// What the sidebar's contents list should do with the chapter being read: which entry is
/// current, and what the selection does when it changes. Pure logic; the list renders it.
///
/// The contents are laid out as flat indented rows (no disclosure triangles), so a nested entry
/// is visible whenever its section is — there are no ancestors to expand. "An entry that appears
/// twice" resolves to the first row, matching the pages-left caption.
public enum ContentsVisibility {
    /// The current entry's row id, when the position has one (nil: no contents entry matches, or
    /// the book has none).
    public static func currentRow(in nodes: [ContentsNode], at location: ReaderLocation?) -> ContentsNode.ID? {
        guard let target = location?.contentsTarget else { return nil }
        return OutlineRow.rows(nodes, children: \.children).first { $0.node.target == target }?.node.id
    }

    /// The entry to mark as being read, Apple Books-style, with the quieter highlight of an
    /// unfocused selection: the current entry, unless it is the selection itself (which already
    /// shows it). The selection stays the user's (a notes page, a highlight, a clicked chapter
    /// that covers the position); this mark is how the chapter being read stays findable.
    public static func readingMark(current: ContentsNode.ID?, selection: SidebarSelection) -> ContentsNode.ID? {
        guard let current, selection != .contents(current) else { return nil }
        return current
    }

    /// The sidebar selection after the chapter being read changed, Preview-style (its sidebar's
    /// selection follows the page): the current entry becomes selected when the selection is
    /// the book itself or another contents entry. A selected highlight or notes page is the
    /// user's, and is left alone. Nil: leave the selection as it is.
    ///
    /// A selected entry that still covers the position stays: one listing the same place again
    /// (the current row is the first of the two), or a chapter whose own part is being read —
    /// clicking "chapter 2" and landing where "part a" begins must not snap the selection away
    /// from the row the user just clicked.
    public static func followedSelection(_ selection: SidebarSelection, in nodes: [ContentsNode],
                                         at location: ReaderLocation?) -> SidebarSelection? {
        guard let current = currentRow(in: nodes, at: location) else { return nil }
        switch selection {
        case .book:
            return .contents(current)
        case .contents(let id) where id != current:
            guard let selected = ContentsNode.find(id, in: nodes) else { return .contents(current) }
            if selected.target == location?.contentsTarget || ContentsNode.find(current, in: selected.children ?? []) != nil {
                return nil
            }
            return .contents(current)
        default:
            return nil
        }
    }
}
