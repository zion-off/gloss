import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossReaderBridge
import GlossTestSupport

@MainActor
struct SearchHighlightCommandTests {
    @Test("an unchanged query is never re-sent; a new book re-sends it; clearing always lands")
    func unchangedQueries() async throws {
        let lib = TestLibrary()
        let (a, _) = try await lib.book("A")
        let (b, _) = try await lib.book("B")
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.handle(.ready)

        await controller.open(a)
        await controller.handle(.opened(toc: [], openID: driver.lastOpenID))
        await controller.setSearchHighlights("whale")
        await controller.setSearchHighlights("whale")  // a step re-derives the same query
        #expect(driver.searchHighlightCalls == ["whale"])

        await controller.clearSearchHighlights()
        #expect(driver.searchHighlightCalls == ["whale", nil])

        // A hit opens book B mid-session: the same query reaches the new book.
        await controller.open(b)
        await controller.handle(.opened(toc: [], openID: driver.lastOpenID))
        await controller.setSearchHighlights("whale")
        #expect(driver.searchHighlightCalls == ["whale", nil, "whale"])

        // Asked while still opening: it lands once the book shows, exactly once.
        await controller.clearSearchHighlights()
        await controller.open(a)
        await controller.setSearchHighlights("whale")
        #expect(driver.searchHighlightCalls == ["whale", nil, "whale", nil])
        await controller.handle(.opened(toc: [], openID: driver.lastOpenID))
        #expect(driver.searchHighlightCalls == ["whale", nil, "whale", nil, "whale"])
    }

    @Test("closing the book forgets what the engine holds")
    func closeForgets() async throws {
        let lib = TestLibrary()
        let (a, _) = try await lib.book("A")
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.handle(.ready)
        await controller.open(a)
        await controller.handle(.opened(toc: [], openID: driver.lastOpenID))
        await controller.setSearchHighlights("whale")
        await controller.close()
        await controller.setSearchHighlights("whale")  // no book: nothing is sent
        #expect(driver.searchHighlightCalls == ["whale"])
    }
}
