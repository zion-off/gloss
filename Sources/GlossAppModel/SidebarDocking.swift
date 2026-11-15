import Foundation

/// The window's sidebar, Notion-style: docked beside the content (which makes room for it), or
/// undocked, when it floats in over the content without moving it. Undocked, it floats while the
/// pointer is on the window's leading edge or on the panel itself, and while a search shows its
/// results in it. It lingers a moment after the pointer leaves, so a pointer that strays off it
/// for a moment doesn't drop it.
///
/// The view forwards pointer events and calls `settle(_:)` once the linger is over; the rules
/// live here.
public struct SidebarDocking: Equatable, Sendable {
    /// What can hold the floating sidebar open under the pointer.
    public enum Zone: Hashable, Sendable {
        /// A thin strip along the window's leading edge.
        case edge
        /// The floating panel.
        case panel
    }

    /// How long the floating sidebar stays after the pointer leaves it.
    public static let linger: Duration = .milliseconds(300)

    public private(set) var isDocked: Bool
    /// Search results are in the sidebar: undocked, it floats until they go.
    public var holdsForSearch = false
    private var hovered: Set<Zone> = []
    /// The pointer just left; `settle` with this number ends the linger (a later leave
    /// supersedes it, so an old timer never cuts a new linger short).
    private var lingering: Int?
    private var leaves = 0
    /// Undocking with the pointer on the floating panel's place (⌃⌘S with the pointer at the edge):
    /// the sidebar the user just put away shouldn't float straight back, so hovering counts again
    /// once the pointer has left.
    private var waitsForExit = false

    public init(docked: Bool) {
        isDocked = docked
    }

    /// Whether the floating panel shows (never while docked).
    public var isFloating: Bool {
        guard !isDocked else { return false }
        if holdsForSearch { return true }
        return !waitsForExit && (!hovered.isEmpty || lingering != nil)
    }

    /// Docks or undocks it (the sidebar button, View › show sidebar, another window's choice).
    public mutating func setDocked(_ docked: Bool) {
        guard docked != isDocked else { return }
        isDocked = docked
        lingering = nil
        waitsForExit = !docked && !hovered.isEmpty
    }

    /// The pointer entered a zone.
    public mutating func enter(_ zone: Zone) {
        hovered.insert(zone)
    }

    /// The pointer left a zone. Returns the linger to settle after `linger` when this was the last
    /// zone and the sidebar was floating; nil when there is nothing to wait for.
    public mutating func leave(_ zone: Zone) -> Int? {
        let wasFloating = isFloating
        hovered.remove(zone)
        guard hovered.isEmpty else { return nil }
        waitsForExit = false
        guard wasFloating, !isDocked else { return nil }
        leaves += 1
        lingering = leaves
        return leaves
    }

    /// The linger from `leave` is over: the sidebar goes unless the pointer came back (or a later
    /// leave started a new linger).
    public mutating func settle(_ linger: Int) {
        guard lingering == linger else { return }
        lingering = nil
    }
}
