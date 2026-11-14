import AppKit
import Foundation
import GlossAppModel
import GlossCore
import GlossEPUB
import GlossExport
import GlossPDF
import GlossReaderBridge
import GlossReaderEPUB
import GlossReaderKit
import GlossReaderPDF
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
    /// Export and print for the windows: the same service the cli wires.
    let export: ExportModel
    let libraryURL: URL
    /// The Settings window's model (⌘,); the Settings scene reads it.
    let settingsModel: AppSettingsModel
    /// Counts backups under way (manual in any window, automatic) so they don't overlap.
    let backupActivity: BackupActivity
    /// Automatic backup: the Settings window shows it, `prepare()` runs its timer.
    let automaticBackup: AutomaticBackupModel
    private let appearance: AppearanceSource
    private var prepared = false
    /// The app object lives as long as the process, so the observer never needs removing.
    private var settingsObserver: (any NSObjectProtocol)?

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
        let export = ExportModel(service: ExportService(store: store))
        return .success(AppRoot(services: services, export: export, readerDirectory: readerDirectory, libraryURL: url))
    }

    private init(services: GlossServices, export: ExportModel, readerDirectory: URL, libraryURL: URL) {
        let appearance = AppearanceSource()
        self.services = services
        self.export = export
        self.libraryURL = libraryURL
        self.appearance = appearance
        self.settingsModel = AppSettingsModel(services: services)
        let backupActivity = BackupActivity()
        self.backupActivity = backupActivity
        self.automaticBackup = AutomaticBackupModel(services: services, activity: backupActivity)
        self.engines = ReadingEngineRegistry([
            EPUBReadingEngine(readerDirectory: readerDirectory, library: services.library) { appearance.current },
            PDFReadingEngine(library: services.library) { appearance.current },
        ])
        // Reading settings saved in the Settings window (or any window of this process) become
        // what new reader sessions open with; open ones take them live through AppModel.
        // NotificationCenter delivers synchronously on the posting (main) thread (verified
        // against swift-corelibs-foundation), so the hop below is safe on both platforms.
        settingsObserver = NotificationCenter.default.addObserver(forName: .glossSettingsChanged, object: nil, queue: nil) { [weak appearance] note in
            let settings = note.userInfo?[glossReaderSettingsKey] as? ReaderSettings
            MainActor.assumeIsolated {
                guard let appearance, let settings else { return }
                appearance.settings = settings
            }
        }
    }

    /// Once per launch, before the first window shows a book: load the reading settings and
    /// start routine upkeep (expired trash, orphaned link targets, unused blobs).
    func prepare() async {
        guard !prepared else { return }
        prepared = true
        if let settings = try? await ReaderSettingsStore(settings: services.settings).load() {
            appearance.settings = settings
        }
        let services = services
        Task.detached(priority: .utility) {
            try? await services.performMaintenance()
        }
        startAutomaticBackup()
    }

    /// The automatic backup timer: a first look shortly after launch (so opening stays quick),
    /// then every hour. Each look is a cheap "is a day up?" check, which also catches a laptop
    /// that slept through the day; the model decides, and a run is at most once a day.
    private func startAutomaticBackup() {
        let backup = automaticBackup
        Task {
            await backup.load()
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                await backup.runIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }
}

/// The appearance new reader sessions open with: the reading settings, in the system's mode
/// at the moment the session opens (auto-night).
@MainActor final class AppearanceSource {
    var settings = ReaderSettings()

    var current: ReaderAppearance {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return AppearanceStyler().appearance(for: settings, systemIsDark: dark)
    }
}
