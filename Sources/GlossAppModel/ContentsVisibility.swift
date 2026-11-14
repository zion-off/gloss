import Foundation
import GlossCore
import GlossReaderBridge

/// What the sidebar's contents list should do with the chapter being read: which entry is
/// current, and when its row should be scrolled into view. Pure logic; the list renders it.
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

    /// Whether the current row needs scrolling into view: only on a real change of entry — a
    /// page turn inside the chapter, a resize or a restyle relocating with the same entry must
    /// not yank the sidebar back while the user is reading it.
    public static func shouldScroll(previous: ContentsNode.ID?, current: ContentsNode.ID?) -> Bool {
        previous != current && current != nil
    }

    /// How far to scroll: the system's lists centre the row they are asked to show; centring is
    /// also the least movement that guarantees visibility at either edge of a long list.
    public static let scrollAnchor: String = "center"
}
