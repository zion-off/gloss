#if os(macOS)
import Foundation
import GlossCore
import GlossEPUB
import GlossPDF
import GlossReaderBridge
import GlossReaderEPUB
import GlossReaderKit
import GlossStore

/// Why the app couldn't start.
struct CompositionFailure: Error {
    let message: String
}

/// The app's composition root: the only place that knows which store, formats and engines the
/// app uses. Shared by every window.
@MainActor final class AppRoot {
    let services: GlossServices
    let engines: ReadingEngineRegistry
    let libraryURL: URL
    private let appearance: AppearanceSource
    private var prepared = false

    static func load() -> Result<AppRoot, CompositionFailure> {
        let url = LibraryLocation.resolve()
        let store: SQLiteLibraryStore
        do {
            store = try SQLiteLibraryStore.open(at: url, origin: "app-\(ProcessInfo.processInfo.processIdentifier)")
        } catch {
            return .failure(CompositionFailure(message: "\(url.path): \(error.localizedDescription)"))
        }
        guard let readerDirectory = ReaderBundle.directory() else {
            return .failure(CompositionFailure(message: "the reader's files are missing from the app"))
        }
        let formats = FormatRegistry([EPUBFormat(), PDFFormat()])
            .adding(coverExtractor: PDFKitCoverRenderer(), for: .pdf)
        let services = GlossServices(store: store, blobs: store.blobs, formats: formats)
        return .success(AppRoot(services: services, readerDirectory: readerDirectory, libraryURL: url))
    }

    private init(services: GlossServices, readerDirectory: URL, libraryURL: URL) {
        let appearance = AppearanceSource()
        self.services = services
        self.libraryURL = libraryURL
        self.appearance = appearance
        self.engines = ReadingEngineRegistry([
            EPUBReadingEngine(readerDirectory: readerDirectory, library: services.library) { appearance.current },
        ])
    }

    /// Once per launch, before the first window shows a book: load the reading settings and
    /// start routine upkeep (expired trash, orphaned link targets, unused blobs).
    func prepare() async {
        guard !prepared else { return }
        prepared = true
        if let settings = try? await ReaderSettingsStore(settings: services.settings).load() {
            appearance.current = AppearanceStyler().appearance(for: settings)
        }
        let services = services
        Task.detached(priority: .utility) {
            try? await services.performMaintenance()
        }
    }
}

/// The appearance new reader sessions open with.
@MainActor final class AppearanceSource {
    var current = AppearanceStyler().appearance(for: ReaderSettings())
}
#endif
