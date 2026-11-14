import Testing
@testable import GlossMarkdown

@Suite("table widths")
struct TableWidthTests {
    @Test("automatic widths fill the space: proportional when content fits, even shares for the wide columns when not")
    func automatic() {
        #expect(TableWidths.automatic(natural: [50, 150], available: 400) == [100, 300])
        // 300 into 3: the narrow column keeps 40, the wide ones share 260.
        #expect(TableWidths.automatic(natural: [40, 500, 900], available: 300) == [40, 130, 130])
        #expect(TableWidths.automatic(natural: [0, 0], available: 100) == [50, 50])
        #expect(TableWidths.automatic(natural: [], available: 100).isEmpty)
    }

    @Test("resizing trades width between neighbours, never below the minimum, keeping the total")
    func resizing() {
        #expect(TableWidths.resizing([100, 100, 100], divider: 0, by: 30, minimum: 40) == [130, 70, 100])
        #expect(TableWidths.resizing([100, 100, 100], divider: 1, by: 500, minimum: 40) == [100, 160, 40])
        #expect(TableWidths.resizing([30, 30], divider: 0, by: -100, minimum: 40) == [30, 30])  // floor: half of 60
        #expect(TableWidths.resizing([100, 100], divider: 1, by: 10, minimum: 40) == [100, 100])  // no divider after the last
    }

    @Test("fractions round-trip, apply only to the same column count, and prune by table count")
    func storage() {
        let fractions = TableWidths.fractions(of: [100, 300])
        #expect(fractions == [0.25, 0.75])
        #expect(TableWidths.widths(fractions: fractions, available: 800) == [200, 600])
        let stored = TableColumnWidths(fractions: fractions)
        #expect(TableWidths.applicable(stored, columnCount: 2) == [0.25, 0.75])
        #expect(TableWidths.applicable(stored, columnCount: 3) == nil)
        #expect(TableWidths.applicable(TableColumnWidths(fractions: [1, -1]), columnCount: 2) == nil)
        #expect(TableWidths.pruned([0: stored, 2: stored, 5: stored], tableCount: 3).keys.sorted() == [0, 2])
    }
}
