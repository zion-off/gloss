import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossMemoryStore
import GlossTestSupport

/// Review 7: a failed read must not read as "empty" or "reset" — the grid keeps what it showed
/// and the sort keeps this window's choice until a read succeeds.
@MainActor
struct FailedReadsTests {
    /// Services over a store whose reads can fail on demand.
    private func flakyServices() throws -> (GlossServices, FlakyLibraryStore, ManualTimeSource) {
        let clock = ManualTimeSource()
        let base = InMemoryLibraryStore(origin: "test", time: clock)
        let flaky = FlakyLibraryStore(base)
        let blobs = InMemoryBlobStore()
        let services = GlossServices(store: flaky, blobs: blobs, formats: FormatRegistry([FakeFormat()]),
                                      ids: SequentialIDGenerator(), time: clock)
        return (services, flaky, clock)
    }

    @Test("a failed reload keeps the grid's entries")
    func reloadKeepsEntries() async throws {
        let (services, flaky, _) = try flakyServices()
        let model = LibraryModel(services: services)
        let directory = TempDir()
        let file = directory.file("TheFall.fake")
        try FakeFormat.file(title: "The Fall").write(to: file)
        _ = await model.importFiles(at: [file])
        #expect(model.entries.count == 1)
        flaky.failsReads = true
        await model.reload()
        #expect(model.entries.count == 1)  // a failed read must not blank the library
        _ = directory
    }

    @Test("a failed sort read keeps this window's sort")
    func syncKeepsSort() async throws {
        let (services, flaky, _) = try flakyServices()
        let model = LibraryModel(services: services)
        model.sort = .title
        await model.flushSortPersistence()
        flaky.failsReads = true
        model.sort = .author  // another window's choice, say
        await model.syncSort()
        #expect(model.sort == .author)  // the failed read must not reset it to "recent"
    }
}

