/// Where the reader's selection popover points: just under the pointer, on the selected line the
/// button came up nearest, so the popover opens where the user is looking, however long the
/// selection. One made from the keyboard has no pointer: the popover points at its moving end,
/// the end of the last line (the start of the first, extending backwards).
///
/// The reader's TypeScript twin (`web/src/bridge/selection.ts`) runs the same cases
/// (`Tests/Fixtures/bridge/selection-anchor.json`).
public enum SelectionAnchor {
    public struct Point: Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// The anchor, in the coordinates of `lines` and `pointer` (the reader's top-left origin), or
    /// nil when no line has an area. `lines` are the selection's rects in document order; an
    /// element's box around its own lines (a DOM range lists those too) and empty rects (a line
    /// break's) are not lines.
    public static func rect(lines: [ReaderRect], pointer: Point?, backward: Bool) -> ReaderRect? {
        let candidates = lines.filter { $0.width > 0 && $0.height > 0 }
        let lines = candidates.filter { outer in !candidates.contains { $0 != outer && outer.encloses($0) } }
        guard let first = lines.first, let last = lines.last else { return nil }
        guard let pointer else {
            let line = backward ? first : last
            return ReaderRect(x: backward ? line.x : line.x + line.width, y: line.y, width: 1, height: line.height)
        }
        // Nearest by height first: the line the pointer is on (or closest above or below), so the
        // popover opens under it rather than over it; across, among lines side by side (columns).
        var nearest = first
        var nearestDistance = (vertical: Double.infinity, horizontal: Double.infinity)
        for line in lines {
            let distance = line.distance(to: pointer)
            if distance < nearestDistance {
                nearest = line
                nearestDistance = distance
            }
        }
        let x = min(max(pointer.x, nearest.x), nearest.x + nearest.width)
        return ReaderRect(x: x, y: nearest.y, width: 1, height: nearest.height)
    }
}

extension ReaderRect {
    fileprivate func encloses(_ other: ReaderRect) -> Bool {
        x <= other.x && y <= other.y && x + width >= other.x + other.width && y + height >= other.y + other.height
    }

    fileprivate func distance(to point: SelectionAnchor.Point) -> (vertical: Double, horizontal: Double) {
        (max(y - point.y, 0, point.y - (y + height)), max(x - point.x, 0, point.x - (x + width)))
    }
}
