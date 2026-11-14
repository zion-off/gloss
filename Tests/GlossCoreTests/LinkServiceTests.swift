import Foundation
import Testing
@testable import GlossCore
import GlossTestSupport

@Suite("links and highlights")
struct LinkServiceTests {
    @Test("targets are reused for the same locator")
    func reuse() async throws {
        let lib = TestLibrary()
        let (document, _) = try await lib.book()
        let a = try await lib.services.links.target(for: lib.passage("x", at: "cfi-1"), in: document.id)
        let b = try await lib.services.links.target(for: lib.passage("x again", at: "cfi-1"), in: document.id)
        let c = try await lib.services.links.target(for: lib.passage("y", at: "cfi-2"), in: document.id)
        #expect(a.id == b.id)
        #expect(a.id != c.id)
    }

    @Test("add to notes inserts a quote line and links back to the passage")
    func addQuote() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book()
        try await lib.services.pages.updateBody(root.id, to: "my thoughts")
        let (page, target, _) = try await lib.services.links.addQuote(of: lib.passage("one must imagine", at: "c"), in: document.id, to: root.id)
        #expect(page.body == "my thoughts\n> one must imagine [↗](gloss://passage/\(target.id))\n")
        let linked = try await lib.services.links.linkedPassages(in: document.id)
        #expect(linked.map(\.target.id) == [target.id])
        #expect(linked.first?.pages.map(\.id) == [root.id])
        #expect(try await lib.services.links.linkTarget(target.id)?.orphanedSince == nil)
    }

    @Test("orphan marks follow references, and old orphans are swept")
    func orphans() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book()
        let target = try await lib.services.links.target(for: lib.passage("q", at: "c"), in: document.id)
        #expect(try await lib.services.links.linkTarget(target.id)?.orphanedSince != nil)
        try await lib.services.pages.updateBody(root.id, to: "[q](gloss://passage/\(target.id))")
        #expect(try await lib.services.links.linkTarget(target.id)?.orphanedSince == nil)
        try await lib.services.pages.updateBody(root.id, to: "q")
        #expect(try await lib.services.links.linkTarget(target.id)?.orphanedSince == lib.clock.now())
        lib.clock.advance(by: LinkMaintenance.orphanGracePeriod - 1)
        #expect(try await lib.services.linkMaintenance.sweepOrphanedTargets() == 0)
        lib.clock.advance(by: 2)
        #expect(try await lib.services.linkMaintenance.sweepOrphanedTargets() == 1)
        #expect(try await lib.services.links.linkTarget(target.id) == nil)
        #expect(lib.store.tombstones.contains { $0.entity == ChangeEntity.linkTarget && $0.id == target.id.stringValue })
    }

    @Test("references from trashed pages keep targets alive and hide markers")
    func trashedReferences() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id)
        let (_, target, _) = try await lib.services.links.addQuote(of: lib.passage("q", at: "c"), in: document.id, to: child.id)
        try await lib.services.trash.trash(.page, id: child.id.stringValue)
        #expect(try await lib.services.links.linkedPassages(in: document.id).isEmpty)
        lib.clock.advance(by: LinkMaintenance.orphanGracePeriod * 2)
        #expect(try await lib.services.linkMaintenance.sweepOrphanedTargets() == 0)
        #expect(try await lib.services.links.linkTarget(target.id) != nil)
    }

    @Test("removing a target degrades links to plain text and keeps the line")
    func degrade() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book()
        let target = try await lib.services.links.target(for: lib.passage("q", at: "c"), in: document.id)
        try await lib.services.pages.updateBody(root.id, to: "before [the **words**](gloss://passage/\(target.id)) after\nnext line")
        try await lib.services.linkMaintenance.removeTarget(target.id)
        #expect(try await lib.services.pages.page(root.id)?.body == "before the **words** after\nnext line")
        #expect(try await lib.services.links.resolve(.passage(target.id)) == .missing)
    }

    @Test("deleting a highlight never touches link targets")
    func highlightIndependence() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book()
        let passage = lib.passage("q", at: "c")
        let highlight = try await lib.services.highlights.add(passage, color: .green, in: document.id)
        let (_, target, _) = try await lib.services.links.addQuote(of: passage, in: document.id, to: root.id)
        try await lib.services.highlights.delete(highlight.id)
        #expect(try await lib.services.highlights.highlights(in: document.id).isEmpty)
        #expect(try await lib.services.links.linkedPassages(in: document.id).map(\.target.id) == [target.id])
        #expect(lib.store.tombstones.contains { $0.entity == ChangeEntity.highlight })
    }

    @Test("highlights recolor, restore and sort by position")
    func highlights() async throws {
        let lib = TestLibrary()
        let (document, _) = try await lib.book()
        let late = try await lib.services.highlights.add(lib.passage("b", at: "2", progression: 0.9), in: document.id)
        let early = try await lib.services.highlights.add(lib.passage("a", at: "1", progression: 0.1), color: .pink, in: document.id)
        #expect(try await lib.services.highlights.highlights(in: document.id).map(\.id) == [early.id, late.id])
        try await lib.services.highlights.recolor(late.id, to: .purple)
        let deleted = try #require(try await lib.services.highlights.delete(late.id))
        try await lib.services.highlights.restore(deleted)
        #expect(try await lib.services.highlights.highlight(late.id)?.color == .purple)
    }

    @Test("links resolve to passages, pages, books, the trash or nothing")
    func resolution() async throws {
        let lib = TestLibrary()
        let (document, root) = try await lib.book()
        let target = try await lib.services.links.target(for: lib.passage("q", at: "c"), in: document.id)
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "sub")
        #expect(try await lib.services.links.resolve(.passage(target.id)) == .passage(target, document))
        #expect(try await lib.services.links.resolve(.document(document.id)) == .document(document))
        guard case .page(let page, _) = try await lib.services.links.resolve(.page(child.id)) else { Issue.record(); return }
        #expect(page.id == child.id)
        let entry = try await lib.services.trash.trash(.page, id: child.id.stringValue)
        #expect(try await lib.services.links.resolve(.page(child.id)) == .inTrash(title: "sub", entryID: entry.id))
        #expect(try await lib.services.links.resolve(.page(PageID(GlossID(high: 1, low: 1)))) == .missing)
    }
}
