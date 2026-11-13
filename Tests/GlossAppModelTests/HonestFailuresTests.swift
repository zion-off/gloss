import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossReaderBridge
import GlossTestSupport

/// Review 7: failures say so. A dead undo (the entry was purged from the cli between the toast
/// and its click) and a dead restore must tell the user, not stay silent; and an import that a
/// Finder double-click brought in names the real reason it couldn't be read.
@MainActor
struct HonestFailuresTests {
    @Test("a dead undo says so instead of leaving a silent toast")
    func deadUndo() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book("Camus")
        let app = AppModel(services: lib.services)
        guard let entry = await app.moveToTrash(book) else { struct E: Error {}; throw E() }
        try await lib.services.trash.purge(entry.id)  // gone for good before the undo
        let restored = await app.undoTrash(entry)
        #expect(restored == nil)
        #expect(app.deletion.toast?.message == "couldn't put it back — it may have gone for good")
        #expect(app.deletion.toast?.entry == nil)  // no dead undo button
    }

    @Test("a dead restore says so in the trash view's line")
    func deadRestore() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book("Camus")
        let trash = TrashModel(services: lib.services)
        let entry = try await lib.services.trash.trash(.document, id: book.id.stringValue)
        try await lib.services.trash.purge(entry.id)
        let restored = await trash.restore(entry.id)
        #expect(restored.isEmpty)
        #expect(trash.restoreProblem == "couldn't put it back — it may have gone for good")
    }

    @Test("a Finder open of a damaged book names the format's reason")
    func importReason() async throws {
        struct BrokenFormat: DocumentFormat {
            let kind = DocumentKind("broken")
            let badge = "broken"
            let shelf = LibraryShelf("broken")
            var fileExtensions: [String] { ["broken"] }
            func sniff(_ prefix: Data) -> Bool { prefix.starts(with: Data("BROKEN".utf8)) }
            func readMetadata(from data: Data) throws -> ImportedMetadata {
                throw GlossError.invalid("it looks damaged, so gloss couldn't read it")
            }
        }
        let lib = TestLibrary(formats: [FakeFormat(), BrokenFormat()])
        let app = AppModel(services: lib.services)
        let directory = TempDir()
        let file = directory.file("bad.broken")
        try Data("BROKEN junk".utf8).write(to: file)
        _ = await app.open(url: file)
        #expect(app.externalURLMessage?.contains("it looks damaged") == true)
        _ = directory
    }
}
