import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossMemoryStore
import GlossTestSupport

/// Review 7: windows in one process hear each other's writes. The change journal's origin is
/// per-process, so a second window's monitor never saw the first's trashing, imports, details
/// edits, restores or opens — each window now posts what it wrote (addressed to the shared
/// store) and the others apply it through their external-change reaction.
@MainActor
struct LocalChangesTests {
    @Test("a book trashed in one window closes in the other")
    func crossWindowTrash() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book("Camus")
        let appA = AppModel(services: lib.services)
        let appB = AppModel(services: lib.services)
        try await appA.workspace.openDocument(book.id)
        try await appB.workspace.openDocument(book.id)
        _ = await appA.moveToTrash(book)
        await appB.flushLocalChanges()
        #expect(appB.workspace.document == nil)  // the trashed book closes in the other window
        #expect(appB.reader.document == nil)
        #expect(appB.trash.items.isEmpty == false)  // its badge counts the new entry
        // The trashing window does not hear its own post (no double reaction).
        #expect(appA.trash.items.count == 1)
        _ = root
    }

    @Test("an import in one window reaches the other's grid")
    func crossWindowImport() async throws {
        let lib = TestLibrary()
        let appA = AppModel(services: lib.services)
        let appB = AppModel(services: lib.services)
        await appA.library.reload()
        await appB.library.reload()
        #expect(appB.library.entries.isEmpty)
        let directory = TempDir()
        let file = directory.file("TheFall.fake")
        try FakeFormat.file(title: "The Fall").write(to: file)
        _ = directory  // keeps the temp folder alive through the import
        _ = await appA.library.importFiles(at: [file])
        await appB.flushLocalChanges()
        #expect(appB.library.entries.map(\.document.title) == ["The Fall"])
    }

    @Test("a restore in one window returns the book to the other's grid")
    func crossWindowRestore() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book("Camus")
        let appA = AppModel(services: lib.services)
        let appB = AppModel(services: lib.services)
        guard let entry = await appA.moveToTrash(book) else { struct E: Error {}; throw E() }
        await appB.flushLocalChanges()
        #expect(appB.library.entries.isEmpty)
        _ = await appA.undoTrash(entry)
        await appB.flushLocalChanges()
        #expect(appB.library.entries.map(\.document.title) == ["Camus"])
        #expect(appB.trash.items.isEmpty)
    }

    @Test("a details edit in one window refreshes the book in the other")
    func crossWindowDetails() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book("Camus")
        let appA = AppModel(services: lib.services)
        let appB = AppModel(services: lib.services)
        try await lib.services.library.updateDetails(book.id, title: "The Fall")
        await appA.refreshAfterDetailsEdit(of: book.id)  // what the details sheet calls after a save
        await appB.flushLocalChanges()
        await appB.library.reload()  // the reaction invalidated the cache; the reload sees the new title
        #expect(appB.library.entries.map(\.document.title) == ["The Fall"])
    }

    @Test("windows over another library never hear this one")
    func objectFiltered() async throws {
        let libA = TestLibrary()
        let libB = TestLibrary()
        let (book, _) = try await libA.book("Camus")
        let appA = AppModel(services: libA.services)
        let appB = AppModel(services: libB.services)
        _ = await appA.moveToTrash(book)
        await appB.flushLocalChanges()
        #expect(appB.trash.items.isEmpty)  // a different store: nothing to hear
    }
}
