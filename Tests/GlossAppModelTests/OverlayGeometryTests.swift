import Testing
@testable import GlossAppModel

@Suite("overlay geometry")
struct OverlayGeometryTests {
    @Test("flipping a rect turns bottom-left into top-left inside the container")
    func flip() {
        let rect = OverlayRect(x: 10, y: 100, width: 50, height: 12)
        #expect(OverlayGeometry.flipUp(rect, inHeight: 400) == OverlayRect(x: 10, y: 400 - 112, width: 50, height: 12))
        // A rect at the very bottom lands at the very top, and vice versa.
        #expect(OverlayGeometry.flipUp(OverlayRect(x: 0, y: 0, width: 1, height: 20), inHeight: 400).minY == 380)
        #expect(OverlayGeometry.flipUp(OverlayRect(x: 0, y: 380, width: 1, height: 20), inHeight: 400).minY == 0)
    }

    @Test("clamping keeps the overlay inside, centring when there's no room")
    func clamp() {
        #expect(OverlayGeometry.clampCenter(20, width: 100, in: 500) == 58)
        #expect(OverlayGeometry.clampCenter(490, width: 100, in: 500) == 442)
        #expect(OverlayGeometry.clampCenter(-5, width: 100, in: 500) == 58)
        #expect(OverlayGeometry.clampCenter(30, width: 100, in: 90) == 45)
    }

    @Test("above prefers the space over the anchor, falling below when there's none")
    func above() {
        let anchor = OverlayRect(x: 0, y: 100, width: 60, height: 20)
        #expect(OverlayGeometry.above(anchor: anchor, height: 30) == 100 - 6 - 30)
        // The anchor sits at the very top: the overlay goes under it instead.
        #expect(OverlayGeometry.above(anchor: OverlayRect(x: 0, y: 0, width: 60, height: 20), height: 30) == 20 + 6)
    }

    @Test("below centres the overlay under the anchor")
    func below() {
        let anchor = OverlayRect(x: 0, y: 100, width: 60, height: 20)
        #expect(OverlayGeometry.belowCenter(anchor: anchor, height: 250) == 120 + 6 + 125)
    }
}
