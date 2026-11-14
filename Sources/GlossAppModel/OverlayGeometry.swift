import Foundation

/// A rectangle in points, portable (CoreGraphics doesn't exist on Linux). AppKit's `NSRect`
/// converts at the boundary.
public struct OverlayRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// A size in points, portable.
public struct OverlaySize: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Where a menu dropped from an anchor goes.
public struct MenuPlacement: Hashable, Sendable {
    /// Its top-left corner, and the height it gets: its own, or the room on its side when that's
    /// less (it scrolls).
    public var frame: OverlayRect
    /// Above the anchor, not below it.
    public var flipped: Bool

    public init(frame: OverlayRect, flipped: Bool) {
        self.frame = frame
        self.flipped = flipped
    }
}

/// Geometry for overlays anchored to text, in pure math so it's Linux-tested.
///
/// AppKit hands out rects in a view's own space, which is bottom-left-origin unless the view is
/// flipped (and the docs don't promise which a scroll view is). SwiftUI's `.position` wants
/// top-left-origin coordinates. Every overlay anchor crosses that boundary exactly once, here,
/// and only after asking the view (reviews 5 and 6).
public enum OverlayGeometry {
    /// A rect in an AppKit view's coordinates, in SwiftUI's top-left-origin space: as it is when
    /// the view is flipped (already top-left), mirrored inside its `height` otherwise.
    public static func topLeft(_ rect: OverlayRect, inHeight height: Double, flipped: Bool) -> OverlayRect {
        flipped ? rect : flipUp(rect, inHeight: height)
    }

    /// A rect in AppKit's bottom-left-origin space, flipped into SwiftUI's top-left-origin
    /// space inside a container `height` points tall.
    public static func flipUp(_ rect: OverlayRect, inHeight height: Double) -> OverlayRect {
        OverlayRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Keeps an overlay of `width` centred at `x` inside `0…available`, with `margin` to spare.
    /// A container too narrow for the overlay centres it.
    public static func clampCenter(_ x: Double, width: Double, in available: Double, margin: Double = 8) -> Double {
        let half = width / 2 + margin
        guard available > 2 * half else { return available / 2 }
        return min(max(x, half), available - half)
    }

    /// Where an overlay of `height` goes above an anchor: `gap` above it, but never above
    /// `minY`; falls back to `gap` below the anchor's bottom when it doesn't fit on top.
    /// Returns the overlay's top edge.
    public static func above(anchor: OverlayRect, height: Double, gap: Double = 6, minY: Double = 0) -> Double {
        let top = anchor.minY - gap - height
        return top >= minY ? top : anchor.maxY + gap
    }

    /// Where a menu of `size` dropped from `anchor` goes inside `available`, all in top-left
    /// space, the way the system's popovers and menus place themselves: left edge on the
    /// anchor's, `gap` under it; above it (bottom edge on the anchor) when it doesn't fit below
    /// and there's more room on top; slid sideways only as far as it takes to stay `margin`
    /// inside. A menu taller than its side gets that side's room and scrolls; a container
    /// narrower than the menu centres it.
    ///
    /// `kept` is the side the menu already took: it stays there while the menu fits, or while it
    /// doesn't fit on the other side either, so a list that shrinks or grows as it's filtered
    /// never jumps across the line.
    public static func menuPlacement(anchor: OverlayRect, size: OverlaySize, in available: OverlayRect,
                                     keepingFlipped kept: Bool? = nil, gap: Double = 4, margin: Double = 8) -> MenuPlacement {
        let below = available.maxY - margin - (anchor.maxY + gap)
        let above = anchor.minY - gap - (available.minY + margin)
        let fitsBelow = size.height <= below
        let fitsAbove = size.height <= above
        let flipped = switch kept {
        case nil: !fitsBelow && above > below
        case true?: fitsAbove || !fitsBelow
        case false?: !fitsBelow && fitsAbove
        }
        let height = min(size.height, max(0, flipped ? above : below))
        let y = flipped ? anchor.minY - gap - height : anchor.maxY + gap
        let x = available.width >= size.width + 2 * margin
            ? min(max(anchor.minX, available.minX + margin), available.maxX - margin - size.width)
            : available.midX - size.width / 2
        return MenuPlacement(frame: OverlayRect(x: x, y: y, width: size.width, height: height), flipped: flipped)
    }
}
