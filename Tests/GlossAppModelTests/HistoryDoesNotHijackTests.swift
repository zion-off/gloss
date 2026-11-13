import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossReaderBridge
import GlossTestSupport

/// Review 7: reader history moves the reader, never the window. While the grid or the trash is
/// the detail column, ⌘[ / ⌘] still step the reader (behind it), but the window stays where the
/// user is.
@MainActor
struct HistoryDoesNotHijackTests {
    @Test("reader back while the grid shows moves the reader, not the window")
    func backBehindTheGrid() async throws {
        let lib = TestLibrary()
        let (a, _) = try await lib.book("A")
        let (b, bRoot) = try await lib.book("B")
        let (_, target, _) = try await lib.services.links.addQuote(of: lib.passage("q", at: "c"), in: b.id, to: bRoot.id)
        let app = AppModel(services: lib.services)
        try await app.workspace.openDocument(a.id)
        await app.follow(.passage(target.id))  // reader: B (history: A → B)
        await app.select(.library(nil))        // the grid is the detail column
        #expect(app.workspace.sidebar == .library(nil))
        try await app.workspace.goBackInReader()
        #expect(app.workspace.document?.id == a.id)  // the reader stepped back…
        #expect(app.workspace.sidebar == .library(nil))  // …behind the grid; the window stayed
    }
}
