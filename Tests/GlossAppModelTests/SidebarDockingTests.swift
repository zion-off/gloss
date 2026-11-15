import Testing
@testable import GlossAppModel

@Suite("sidebar docking")
struct SidebarDockingTests {
    @Test("docked, it never floats, whatever the pointer or the search does")
    func dockedNeverFloats() {
        var sidebar = SidebarDocking(docked: true)
        sidebar.enter(.edge)
        sidebar.enter(.panel)
        sidebar.holdsForSearch = true
        #expect(!sidebar.isFloating)
        let edgeLinger = sidebar.leave(.edge)
        #expect(edgeLinger == nil)
        let panelLinger = sidebar.leave(.panel)
        #expect(panelLinger == nil)  // nothing floated, so nothing lingers
    }

    @Test("undocked, the edge or the panel floats it")
    func hoverFloats() {
        for zone in [SidebarDocking.Zone.edge, .panel] {
            var sidebar = SidebarDocking(docked: false)
            #expect(!sidebar.isFloating)
            sidebar.enter(zone)
            #expect(sidebar.isFloating)
        }
    }

    @Test("it lingers after the pointer leaves, then goes when the linger settles")
    func lingers() throws {
        var sidebar = SidebarDocking(docked: false)
        sidebar.enter(.edge)
        let lingerLeave = sidebar.leave(.edge)
        let linger = try #require(lingerLeave)
        #expect(sidebar.isFloating)
        sidebar.settle(linger)
        #expect(!sidebar.isFloating)
    }

    @Test("crossing from the edge to the panel keeps it, in either order of events")
    func crossingKeepsIt() throws {
        var leaveFirst = SidebarDocking(docked: false)
        leaveFirst.enter(.edge)
        let lingerLeave = leaveFirst.leave(.edge)
        let linger = try #require(lingerLeave)
        leaveFirst.enter(.panel)
        leaveFirst.settle(linger)
        #expect(leaveFirst.isFloating)

        var enterFirst = SidebarDocking(docked: false)
        enterFirst.enter(.edge)
        enterFirst.enter(.panel)
        let edgeLinger = enterFirst.leave(.edge)
        #expect(edgeLinger == nil)  // still on the panel: nothing to wait for
        #expect(enterFirst.isFloating)
    }

    @Test("an old linger never cuts a newer one short")
    func staleLinger() throws {
        var sidebar = SidebarDocking(docked: false)
        sidebar.enter(.panel)
        let firstLeave = sidebar.leave(.panel)
        let first = try #require(firstLeave)
        sidebar.enter(.panel)
        let secondLeave = sidebar.leave(.panel)
        let second = try #require(secondLeave)
        sidebar.settle(first)
        #expect(sidebar.isFloating)
        sidebar.settle(second)
        #expect(!sidebar.isFloating)
    }

    @Test("search results hold it open until they go, then it goes unless the pointer is on it")
    func searchHolds() {
        var away = SidebarDocking(docked: false)
        away.holdsForSearch = true
        #expect(away.isFloating)
        away.holdsForSearch = false
        #expect(!away.isFloating)

        var onIt = SidebarDocking(docked: false)
        onIt.holdsForSearch = true
        onIt.enter(.panel)
        onIt.holdsForSearch = false
        #expect(onIt.isFloating)
    }

    @Test("docking replaces the floating panel, and a pending linger can't bring it back")
    func dockingWhileFloating() throws {
        var sidebar = SidebarDocking(docked: false)
        sidebar.enter(.edge)
        let lingerLeave = sidebar.leave(.edge)
        let linger = try #require(lingerLeave)
        sidebar.setDocked(true)
        #expect(sidebar.isDocked)
        #expect(!sidebar.isFloating)
        sidebar.setDocked(false)
        sidebar.settle(linger)
        #expect(!sidebar.isFloating)
    }

    @Test("undocking with the pointer at the edge doesn't float it back until the pointer has left and returned")
    func undockWaitsForExit() {
        var sidebar = SidebarDocking(docked: true)
        sidebar.enter(.edge)
        sidebar.setDocked(false)
        #expect(!sidebar.isFloating)
        let edgeLinger = sidebar.leave(.edge)
        #expect(edgeLinger == nil)  // it wasn't floating: no linger
        sidebar.enter(.edge)
        #expect(sidebar.isFloating)
    }

    @Test("undocking from the keyboard with the pointer elsewhere leaves it hidden")
    func undockFromKeyboard() {
        var sidebar = SidebarDocking(docked: true)
        sidebar.setDocked(false)
        #expect(!sidebar.isFloating)
        sidebar.enter(.edge)
        #expect(sidebar.isFloating)
    }
}
