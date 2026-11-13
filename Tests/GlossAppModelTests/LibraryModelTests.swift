import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossMemoryStore
import GlossNotes
import GlossTestSupport

@MainActor
struct GeneratedCoverTests {
    @Test("the tint never changes for the same book")
    func stableTint() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book("Moby-Dick", author: "Melville")
        let first = GeneratedCoverStyle(document: book)
        let second = GeneratedCoverStyle(document: book)
        #expect(first == second)
        // A fresh document value with the same id picks the same swatch.
        let copy = Document(id: book.id, kind: book.kind, title: book.title, author: book.author,
                            contentHash: book.contentHash, fileSize: book.fileSize,
                            addedAt: book.addedAt, updatedAt: book.updatedAt)
        #expect(GeneratedCoverStyle(document: copy).swatch == first.swatch)
    }

    @Test("different books land on different tints")
    func variedTints() async throws {
        let lib = TestLibrary()
        var swatches: Set<GeneratedCoverStyle.Swatch> = []
        for index in 0..<12 {
            let (book, _) = try await lib.book("Book \(index)")
            swatches.insert(GeneratedCoverStyle(document: book).swatch)
        }
        #expect(swatches.count > 1)
        // Every tint is a palette colour, dark enough for white text.
        for swatch in swatches {
            #expect(GeneratedCoverStyle.palette.contains(swatch))
        }
    }

    @Test("titles wrap to at most three short lines, cut with an ellipsis")
    func wrappedTitles() {
        #expect(GeneratedCoverStyle.wrap("Dune") == ["Dune"])
        #expect(GeneratedCoverStyle.wrap("the left hand of darkness") == ["the left hand", "of darkness"])
        #expect(GeneratedCoverStyle.wrap("  untitled  ") == ["untitled"])
        #expect(GeneratedCoverStyle.wrap("") == [""])
        let long = GeneratedCoverStyle.wrap("the absolutely true diary of a part-time indian")
        #expect(long.count == 3)
        #expect(long.last?.hasSuffix("…") == true)
        #expect(long.allSatisfy { $0.count <= GeneratedCoverStyle.lineLimit })
        // A word longer than a line is split, not overflowed.
        let split = GeneratedCoverStyle.wrap("antidisestablishmentarianism")
        #expect(split.allSatisfy { $0.count <= GeneratedCoverStyle.lineLimit })
    }

    @Test("the author is trimmed and empty authors disappear")
    func author() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book("A Book", author: "  Ursula K. Le Guin  ")
        let style = GeneratedCoverStyle(document: book)
        #expect(style.author == "Ursula K. Le Guin")
        let (plain, _) = try await lib.book("B Book", author: "   ")
        #expect(GeneratedCoverStyle(document: plain).author == nil)
    }
}

@MainActor
struct LibrarySortTests {
    @Test("the sort persists in the library database and reloads")
    func persists() async throws {
        let lib = TestLibrary()
        _ = try await lib.book("Beta", author: "A")
        lib.clock.advance(by: 1)
        _ = try await lib.book("Alpha", author: "B")
        let model = LibraryModel(services: lib.services)
        await model.loadPersistedSort()
        #expect(model.sort == .recent)
        model.sort = .title
        await model.settle()
        await model.flushSortPersistence()
        #expect(try await lib.services.settings.value(LibrarySettings.sort) == .title)

        // A fresh window (a fresh LibraryModel) loads the same choice.
        let fresh = LibraryModel(services: lib.services)
        await fresh.loadPersistedSort()
        #expect(fresh.sort == .title)
    }

    @Test("rapid sort changes persist the last one")
    func race() async throws {
        let lib = TestLibrary()
        let model = LibraryModel(services: lib.services)
        for sort in [LibrarySort.author, .title, .dateAdded, .author, .title] { model.sort = sort }
        await model.settle()
        await model.flushSortPersistence()
        #expect(try await lib.services.settings.value(LibrarySettings.sort) == .title)
    }

    @Test("every window agrees: another window's choice syncs this one")
    func windowsAgree() async throws {
        let lib = TestLibrary()
        let a = LibraryModel(services: lib.services)
        let b = LibraryModel(services: lib.services)
        a.sort = .author
        await a.settle()
        await a.flushSortPersistence()
        #expect(try await lib.services.settings.value(LibrarySettings.sort) == .author)
        // The other window's poll picks the stored choice up (the window loop calls syncSort).
        await b.syncSort()
        #expect(b.sort == .author)
        await b.settle()
        #expect(b.entries.isEmpty)  // the reload followed the sync (nothing imported yet)
    }
}
