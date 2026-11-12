import Foundation
import GlossCore
import GlossTestSupport
@testable import GlossStore

/// A temporary directory removed when the value is deinitialised.
final class TemporaryDirectory: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// Core services over a real SQLite store.
struct SQLiteTestLibrary {
    let services: GlossServices
    let store: SQLiteLibraryStore
    let clock: ManualTimeSource

    init(store: SQLiteLibraryStore? = nil, clock: ManualTimeSource = ManualTimeSource()) throws {
        let store = try store ?? SQLiteLibraryStore.inMemory(time: clock)
        self.store = store
        self.clock = clock
        services = GlossServices(store: store, blobs: store.blobs, formats: FormatRegistry([FakeFormat()]), ids: UUIDv7Generator(time: clock), time: clock)
    }

    func book(_ title: String = "A Book", chapters: [String] = ["once upon a time"]) async throws -> (Document, Page) {
        let document = try await services.imports.importData(FakeFormat.file(title: title, chapters: chapters), filename: "\(title).fake").document
        return (document, try await services.pages.rootPage(of: document.id)!)
    }

    func passage(_ quote: String, at value: String) -> Passage {
        Passage(locator: Locator(scheme: FakeFormat.scheme, value: value), quote: quote, label: "chapter 1", progression: 0.3)
    }
}
