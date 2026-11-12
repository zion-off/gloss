import Foundation
import Testing
@testable import GlossCore
import GlossTestSupport

@Suite("trash")
struct TrashTests {
    @Test("trashing a page takes its subtree; restoring brings it all back")
    func cascade() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book()
        let a = try await lib.services.pages.createSubpage(under: root.id, title: "a")
        let a1 = try await lib.services.pages.createSubpage(under: a.id, title: "a1")
        let entry = try await lib.services.trash.trash(.page, id: a.id.stringValue)
        #expect(entry.title == "a")
        #expect(try await lib.services.pages.tree(of: document.id).root.children.isEmpty)
        #expect(try await lib.services.pages.page(a1.id)?.trash?.entryID == entry.id)
        try await lib.services.trash.restore(entry.id)
        #expect(try await lib.services.pages.tree(of: document.id).root.walk().count == 3)
        #expect(try await lib.services.trash.entries().isEmpty)
    }

    @Test("the root page can't be trashed on its own")
    func rootPage() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        await #expect(throws: GlossError.self) { try await lib.services.trash.trash(.page, id: root.id.stringValue) }
    }

    @Test("restoring a page under a trashed parent brings the parent back")
    func ancestors() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book()
        let parent = try await lib.services.pages.createSubpage(under: root.id, title: "parent")
        let sibling = try await lib.services.pages.createSubpage(under: parent.id, title: "sibling")
        let child = try await lib.services.pages.createSubpage(under: parent.id, title: "child")
        let childEntry = try await lib.services.trash.trash(.page, id: child.id.stringValue)
        let parentEntry = try await lib.services.trash.trash(.page, id: parent.id.stringValue)
        #expect(try await lib.services.pages.page(child.id)?.trash?.entryID == childEntry.id)
        let restored = try await lib.services.trash.restore(childEntry.id)
        #expect(Set(restored.map(\.id)) == [childEntry.id, parentEntry.id])
        let titles = try await lib.services.pages.tree(of: document.id).root.walk().map(\.page.title)
        #expect(titles == ["A Book", "parent", "sibling", "child"])
        _ = sibling
    }

    @Test("restoring a page of a trashed book restores the book")
    func pageOfTrashedBook() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book()
        let page = try await lib.services.pages.createSubpage(under: root.id)
        let pageEntry = try await lib.services.trash.trash(.page, id: page.id.stringValue)
        let bookEntry = try await lib.services.trash.trash(.document, id: document.id.stringValue)
        #expect(try await lib.services.library.entries().isEmpty)
        #expect(try await lib.services.pages.page(root.id)?.trash?.entryID == bookEntry.id)
        try await lib.services.trash.restore(pageEntry.id)
        #expect(try await lib.services.library.entries().count == 1)
        #expect(try await lib.services.pages.page(page.id)?.trash == nil)
        #expect(try await lib.services.pages.page(root.id)?.trash == nil)
    }

    @Test("purging a book removes what it owns and degrades links from other books")
    func purgeBook() async throws {
        let lib = TestLibrary()
        let (camus, camusRoot) = try await lib.book("Camus")
        let (didion, didionRoot) = try await lib.book("Didion")
        let (_, target, _) = try await lib.services.links.addQuote(of: lib.passage("absurd", at: "c"), in: camus.id, to: didionRoot.id)
        try await lib.services.pages.append("see [camus notes](gloss://page/\(camusRoot.id))", to: didionRoot.id)
        _ = try await lib.services.highlights.add(lib.passage("h", at: "h"), in: camus.id)
        let entry = try await lib.services.trash.trash(.document, id: camus.id.stringValue)
        // While in the trash, links still point at it.
        #expect(try await lib.services.links.resolve(.passage(target.id)) == .inTrash(title: "Camus", entryID: entry.id))
        try await lib.services.trash.purge(entry.id)
        let body = try #require(try await lib.services.pages.page(didionRoot.id)).body
        #expect(body == "> absurd ↗\nsee camus notes")
        #expect(try await lib.services.pages.page(camusRoot.id) == nil)
        #expect(try await lib.services.highlights.highlights(in: camus.id).isEmpty)
        #expect(try await lib.services.blobCollector.collect() == 1)
        #expect(try await lib.services.library.entries().map(\.id) == [didion.id])
        #expect(try await lib.services.search.search("camus", in: .library).isEmpty)
    }

    @Test("purging a page degrades links to it and takes earlier-trashed descendants")
    func purgePage() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let page = try await lib.services.pages.createSubpage(under: root.id, title: "doomed", appendBlockLine: true)
        let grandchild = try await lib.services.pages.createSubpage(under: page.id)
        _ = try await lib.services.trash.trash(.page, id: grandchild.id.stringValue)
        let entry = try await lib.services.trash.trash(.page, id: page.id.stringValue)
        try await lib.services.trash.purge(entry.id)
        #expect(try await lib.services.pages.page(root.id)?.body == "doomed\n")
        #expect(try await lib.services.pages.page(grandchild.id) == nil)
        #expect(try await lib.services.trash.entries().isEmpty)
    }

    @Test("expiry follows the current retention setting, including never")
    func retention() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let page = try await lib.services.pages.createSubpage(under: root.id)
        _ = try await lib.services.trash.trash(.page, id: page.id.stringValue)
        lib.clock.advance(by: 29 * 86_400)
        #expect(try await lib.services.trash.purgeExpired() == 0)
        try await lib.services.settings.set(nil, for: TrashSettings.retentionDays)
        lib.clock.advance(by: 365 * 86_400)
        #expect(try await lib.services.trash.purgeExpired() == 0)
        try await lib.services.settings.set(7, for: TrashSettings.retentionDays)
        #expect(try await lib.services.trash.purgeExpired() == 1)
    }

    @Test("emptying the trash purges everything")
    func empty() async throws {
        let lib = TestLibrary()
        let (a, _) = try await lib.book("a")
        let (b, _) = try await lib.book("b")
        _ = try await lib.services.trash.trash(.document, id: a.id.stringValue)
        _ = try await lib.services.trash.trash(.document, id: b.id.stringValue)
        try await lib.services.trash.empty()
        #expect(try await lib.services.trash.entries().isEmpty)
        #expect(try await lib.store.read { try $0.documents.documents(.any) }.isEmpty)
    }
}
