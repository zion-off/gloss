import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossMemoryStore
import GlossTestSupport

/// Review 7: a stale switcher query must never overwrite the newest results. The stale task is
/// cancelled (as the debounce does) while parked inside its store read; when it resumes, the
/// cancellation check drops it.
@MainActor
struct StaleSwitcherQueryTests {
    @Test("a cancelled query landing late cannot overwrite the newest results")
    func staleQueryLoses() async throws {
        let clock = ManualTimeSource()
        let base = InMemoryLibraryStore(origin: "test", time: clock)
        let flaky = FlakyLibraryStore(base)
        let blobs = InMemoryBlobStore()
        let services = GlossServices(store: flaky, blobs: blobs, formats: FormatRegistry([FakeFormat()]),
                                     ids: SequentialIDGenerator(), time: clock)
        // Two books in the flaky-backed library itself.
        _ = try await services.imports.importData(FakeFormat.file(title: "The Fall"), filename: "a.fake")
        _ = try await services.imports.importData(FakeFormat.file(title: "The Plague"), filename: "b.fake")
        // The switcher searches it: the slow query parks in its read.
        let model = QuickSwitcherModel(services: services)
        flaky.parkNextRead = true
        let slow = Task { await model.search("plague") }
        while flaky.parkedReads < 1 { await Task.yield() }  // the slow query is parked mid-read
        // A newer query (the debounced task for the next keystroke) runs to completion.
        let fast = Task { await model.search("fall") }
        await fast.value
        let fresh = model.items
        #expect(!fresh.isEmpty)
        // The stale task is cancelled — exactly what the debounce does to it — and released.
        slow.cancel()
        flaky.releaseParkedRead()
        await slow.value
        #expect(model.items == fresh)  // the stale query must not have overwritten anything
    }
}
