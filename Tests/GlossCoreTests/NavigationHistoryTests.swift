import Testing
@testable import GlossCore

@Suite("navigation history")
struct NavigationHistoryTests {
    @Test("back and forward walk the visited locations")
    func backForward() {
        var history = NavigationHistory<String>()
        history.visit("a"); history.visit("b"); history.visit("c")
        #expect(history.goBack() == "b")
        #expect(history.goBack() == "a")
        #expect(history.goBack() == nil)
        #expect(history.current == "a")
        #expect(history.goForward() == "b")
        #expect(history.canGoForward)
    }

    @Test("visiting after going back drops the forward stack")
    func branch() {
        var history = NavigationHistory<String>()
        history.visit("a"); history.visit("b")
        history.goBack()
        history.visit("x")
        #expect(!history.canGoForward)
        #expect(history.backStack == ["a"])
    }

    @Test("revisiting the current location adds nothing")
    func duplicate() {
        var history = NavigationHistory<String>()
        history.visit("a"); history.visit("a")
        #expect(!history.canGoBack)
    }

    @Test("replacing the current location keeps the stacks")
    func replace() {
        var history = NavigationHistory<String>()
        history.visit("a"); history.visit("b@1")
        history.replaceCurrent(with: "b@2")
        #expect(history.goBack() == "a")
        #expect(history.goForward() == "b@2")
    }

    @Test("the back stack is bounded")
    func limit() {
        var history = NavigationHistory<Int>(limit: 3)
        for i in 0..<10 { history.visit(i) }
        #expect(history.backStack == [6, 7, 8])
    }

    @Test("removing locations collapses neighbours and moves off a removed current")
    func removal() {
        var history = NavigationHistory<String>()
        for x in ["a", "b", "a", "c"] { history.visit(x) }
        history.removeAll { $0 == "b" }
        #expect(history.backStack == ["a"])
        #expect(history.current == "c")
        history.removeAll { $0 == "c" }
        #expect(history.current == "a")
        #expect(!history.canGoBack)
    }
}
