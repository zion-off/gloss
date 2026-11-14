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

    @Test("a flipped view's rects are already top-left; only an unflipped view's are mirrored")
    func topLeft() {
        let rect = OverlayRect(x: 10, y: 100, width: 50, height: 12)
        #expect(OverlayGeometry.topLeft(rect, inHeight: 400, flipped: true) == rect)
        #expect(OverlayGeometry.topLeft(rect, inHeight: 400, flipped: false) == OverlayGeometry.flipUp(rect, inHeight: 400))
    }

    @Test("a rect's centre lines")
    func centres() {
        let rect = OverlayRect(x: 10, y: 100, width: 50, height: 12)
        #expect(rect.midX == 35)
        #expect(rect.midY == 106)
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

    @Test("a menu drops under its anchor, flips above without room, slides in from the edges and keeps its side")
    func menuPlacement() {
        let window = OverlayRect(x: 0, y: 0, width: 600, height: 400)
        let menu = OverlaySize(width: 260, height: 120)
        func slash(_ x: Double, _ y: Double) -> OverlayRect { OverlayRect(x: x, y: y, width: 7, height: 16) }
        let cases: [(String, OverlayRect, OverlaySize, OverlayRect, Bool?, OverlayRect, Bool)] = [
            ("below, left edge on the slash", slash(100, 50), menu, window, nil,
             OverlayRect(x: 100, y: 70, width: 260, height: 120), false),
            ("no room below: above, bottom edge on the line", slash(100, 330), menu, window, nil,
             OverlayRect(x: 100, y: 206, width: 260, height: 120), true),
            ("near the right edge: slides left", slash(500, 50), menu, window, nil,
             OverlayRect(x: 332, y: 70, width: 260, height: 120), false),
            ("near the left edge: slides right", slash(2, 50), menu, window, nil,
             OverlayRect(x: 8, y: 70, width: 260, height: 120), false),
            ("taller than both sides: the larger side's room", slash(100, 150), OverlaySize(width: 260, height: 300), window, nil,
             OverlayRect(x: 100, y: 170, width: 260, height: 222), false),
            ("tiny container: centred, the larger side's room", slash(10, 10), menu, OverlayRect(x: 0, y: 0, width: 200, height: 100), nil,
             OverlayRect(x: -30, y: 30, width: 260, height: 62), false),
            ("shrunk while filtering: stays above though it fits below now", slash(100, 250), OverlaySize(width: 260, height: 40), window, true,
             OverlayRect(x: 100, y: 206, width: 260, height: 40), true),
        ]
        for (name, anchor, size, available, kept, frame, flipped) in cases {
            let placement = OverlayGeometry.menuPlacement(anchor: anchor, size: size, in: available, keepingFlipped: kept)
            #expect(placement == MenuPlacement(frame: frame, flipped: flipped), "\(name)")
        }
    }
}
