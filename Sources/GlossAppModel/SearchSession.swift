import Foundation
import Observation
import GlossCore

/// A search session's stepping state: the results as one flat list in the order they are shown,
/// which one is current, and moving through them with wraparound. A pure value: the model owns
/// it, the list and the menu only read it.
public struct SearchStepper: Equatable, Sendable {
    public private(set) var hits: [SearchHit] = []
    /// The current hit's index into `hits`; nil when there is nothing to step to.
    public private(set) var current: Int?
    /// Where each section's hits start in `hits`, by section id: a row's place in the list is its
    /// section's start plus its index there, found without searching thousands of hits per row.
    public private(set) var sectionStarts: [String: Int] = [:]

    public init() {}

    /// The results the sections hold, flattened in display order.
    public init(sections: [SearchResultSection]) {
        replace(sections: sections)
    }

    public var count: Int { hits.count }
    public var currentHit: SearchHit? { current.flatMap { hits.indices.contains($0) ? hits[$0] : nil } }
    /// The current hit's place, one-based ("3 of 12"); nil with nothing to step to.
    public var position: (index: Int, count: Int)? {
        current.map { ($0 + 1, hits.count) }
    }

    /// New results: the current hit stays when it is still among them (a query narrowed around
    /// it), else nothing is current — the first step (or click) picks one.
    public mutating func replace(sections: [SearchResultSection]) {
        let old = currentHit
        hits = sections.flatMap(\.hits)
        var start = 0
        sectionStarts = [:]
        for section in sections {
            sectionStarts[section.id] = start
            start += section.hits.count
        }
        current = old.flatMap { hit in hits.firstIndex(of: hit) }
    }

    /// Moves by `delta` with wraparound, making the landed hit current. Nil when there is
    /// nothing to step to.
    @discardableResult
    public mutating func step(by delta: Int) -> SearchHit? {
        guard !hits.isEmpty else { return nil }
        let base = current ?? (delta >= 0 ? hits.count - 1 : 0)  // a first Next starts at the top
        current = (base + delta %% hits.count + hits.count) %% hits.count
        return currentHit
    }

    /// Makes the hit at `index` current (a click, a list selection). Nil when out of range.
    @discardableResult
    public mutating func select(at index: Int) -> SearchHit? {
        guard hits.indices.contains(index) else { return nil }
        current = index
        return currentHit
    }
}

infix operator %%: MultiplicationPrecedence
/// The remainder, always in 0..<rhs (steps wrap around both ways).
fileprivate func %% (lhs: Int, rhs: Int) -> Int {
    let remainder = lhs % rhs
    return remainder < 0 ? remainder + rhs : remainder
}
