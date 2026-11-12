/// Back/forward history for one pane, like a browser or Apple Books (⌘[ and ⌘]).
public struct NavigationHistory<Location: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var backStack: [Location] = []
    public private(set) var current: Location?
    public private(set) var forwardStack: [Location] = []
    public let limit: Int

    public init(limit: Int = 100) {
        self.limit = max(1, limit)
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Moves to a new location. Revisiting the current location is a no-op; anything forward
    /// of here is discarded, as in every browser.
    public mutating func visit(_ location: Location) {
        guard location != current else { return }
        if let current { backStack.append(current) }
        if backStack.count > limit { backStack.removeFirst(backStack.count - limit) }
        current = location
        forwardStack.removeAll()
    }

    /// Updates where we are without creating a history entry (e.g. turning pages updates the
    /// position that "back" will return to).
    public mutating func replaceCurrent(with location: Location) {
        current = location
    }

    @discardableResult
    public mutating func goBack() -> Location? {
        guard let previous = backStack.popLast() else { return nil }
        if let current { forwardStack.append(current) }
        current = previous
        return previous
    }

    @discardableResult
    public mutating func goForward() -> Location? {
        guard let next = forwardStack.popLast() else { return nil }
        if let current { backStack.append(current) }
        current = next
        return next
    }

    /// Drops every entry matching `predicate` (e.g. pages that were trashed).
    public mutating func removeAll(where predicate: (Location) -> Bool) {
        backStack.removeAll(where: predicate)
        forwardStack.removeAll(where: predicate)
        if let current, predicate(current) {
            self.current = backStack.popLast() ?? forwardStack.popLast()
        }
        // Collapse adjacent duplicates created by removals.
        backStack = backStack.reduce(into: []) { result, item in
            if result.last != item { result.append(item) }
        }
        if let current, backStack.last == current, !backStack.isEmpty { backStack.removeLast() }
    }
}
