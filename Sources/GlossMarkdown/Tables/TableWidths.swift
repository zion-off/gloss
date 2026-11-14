/// Column widths someone set by dragging, kept as view state (never in the markdown): the column
/// count they were made for and each column's share of the table's width.
public struct TableColumnWidths: Hashable, Codable, Sendable {
    public var columnCount: Int
    public var fractions: [Double]

    public init(fractions: [Double]) {
        self.columnCount = fractions.count
        self.fractions = fractions
    }
}

/// Width math for drawn tables. Widths are in points; a table always spans the width it is
/// given, so stored fractions of it mean the same thing at any pane width.
public enum TableWidths {
    /// Widths for `natural` content widths (padding included) that add up to `available`. When
    /// everything fits, each column grows in proportion to its content. When it doesn't, columns
    /// whose content fits an even share keep their natural width and the rest share what's left
    /// evenly, wrapping their text.
    public static func automatic(natural: [Double], available: Double) -> [Double] {
        guard !natural.isEmpty else { return [] }
        let available = max(available, 0)
        let natural = natural.map { $0.isFinite ? max($0, 0) : 0 }
        let total = natural.reduce(0, +)
        guard total > 0 else { return natural.map { _ in available / Double(natural.count) } }
        if total <= available {
            return natural.map { $0 + (available - total) * $0 / total }
        }
        var widths = natural
        var remaining = available
        var open = Array(natural.indices)
        while !open.isEmpty {
            let share = remaining / Double(open.count)
            let fitting = open.filter { natural[$0] <= share }
            guard !fitting.isEmpty else {
                for index in open { widths[index] = share }
                break
            }
            for index in fitting { remaining -= natural[index] }
            open.removeAll { fitting.contains($0) }
        }
        return widths
    }

    /// Stored fractions as widths across `available`.
    public static func widths(fractions: [Double], available: Double) -> [Double] {
        let total = fractions.reduce(0, +)
        guard total > 0 else { return fractions.map { _ in 0 } }
        return fractions.map { max(available, 0) * $0 / total }
    }

    /// Each width's share of their sum, for storing.
    public static func fractions(of widths: [Double]) -> [Double] {
        let total = widths.reduce(0, +)
        guard total > 0 else { return widths.map { _ in widths.isEmpty ? 0 : 1 / Double(widths.count) } }
        return widths.map { $0 / total }
    }

    /// Dragging the divider after column `divider` by `delta` points: that column and the next
    /// trade width (the table's width stays the same), and neither gets narrower than `minimum`
    /// (or half their joint width, when even that doesn't fit).
    public static func resizing(_ widths: [Double], divider: Int, by delta: Double, minimum: Double) -> [Double] {
        guard widths.indices.contains(divider), widths.indices.contains(divider + 1), delta.isFinite else { return widths }
        let pair = widths[divider] + widths[divider + 1]
        let floor = min(minimum, pair / 2)
        let left = min(max(widths[divider] + delta, floor), pair - floor)
        var result = widths
        result[divider] = left
        result[divider + 1] = pair - left
        return result
    }

    /// The stored widths' fractions, if they still fit a table of `columnCount` columns.
    /// Otherwise nil: the table lays out automatically until it is resized again.
    public static func applicable(_ stored: TableColumnWidths?, columnCount: Int) -> [Double]? {
        guard let stored, stored.columnCount == columnCount, stored.fractions.count == columnCount, columnCount > 0,
              stored.fractions.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return fractions(of: stored.fractions)
    }

    /// Stored widths without entries for tables a note no longer has (by ordinal).
    public static func pruned(_ stored: [Int: TableColumnWidths], tableCount: Int) -> [Int: TableColumnWidths] {
        stored.filter { $0.key >= 0 && $0.key < tableCount }
    }
}
