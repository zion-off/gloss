import Foundation
import Observation
import GlossCore
import GlossReaderBridge

/// Posted when the Settings window saved (the library is the one store, but a window's change
/// monitor skips its own process's writes, so reading windows hear it here instead).
public extension Notification.Name {
    static let glossSettingsChanged = Notification.Name("gloss.settingsChanged")
}

public extension Notification {
    /// The reading settings a `glossSettingsChanged` notification carries.
    var glossReaderSettings: ReaderSettings? {
        userInfo?[glossReaderSettingsKey] as? ReaderSettings
    }
}

/// The `userInfo` key a `glossSettingsChanged` notification carries reading settings under.
public let glossReaderSettingsKey = "readerSettings"

/// The Settings window's model (⌘,): trash retention and reading settings. Everything persists
/// through `services.settings` into the one SQLite file — never UserDefaults (brief
/// "Constraints"). Edits save debounced (a dragged slider is one save) but stay quiet: only
/// `flushSave()`, which the window calls as it closes, announces them with
/// `glossSettingsChanged`, so open books take the final values once, on close (D-149).
@MainActor @Observable public final class AppSettingsModel {
    /// Days things stay in the trash; nil keeps them forever (brief 39).
    public var retentionDays: Int? = 30 {
        didSet { guard !suppressSave else { return }; scheduleSave() }
    }
    /// The reading settings, edited field by field (D-061: one JSON blob, one key).
    public var reader: ReaderSettings = ReaderSettings() {
        didSet { guard !suppressSave else { return }; scheduleSave() }
    }

    /// The choices the picker offers (brief 39: 7, 30, 90 days, or never).
    public static let retentionChoices: [Int?] = [7, 30, 90, nil]
    /// Why the last save didn't store (the Settings window shows it; nil when it did).
    public private(set) var saveProblem: String?

    private let services: GlossServices
    private let saveDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var saveTask: Task<Void, Never>?
    /// Bumped by every change; only the newest may save.
    private var generation = 0
    private var suppressSave = false
    /// What open windows last heard (or what was loaded): closing without a change says nothing.
    private var announced: (retentionDays: Int?, reader: ReaderSettings)?

    public init(services: GlossServices,
                saveDelay: Duration = .milliseconds(400),
                sleep: @escaping @Sendable (Duration) async throws -> Void = taskSleep) {
        self.services = services
        self.saveDelay = saveDelay
        self.sleep = sleep
    }

    /// Loads what's stored (defaults when nothing is: 30 days, sepia, paginated).
    public func load() async {
        suppressSave = true
        retentionDays = (try? await services.settings.value(TrashSettings.retentionDays)) ?? 30
        reader = (try? await ReaderSettingsStore(settings: services.settings).load()) ?? ReaderSettings()
        suppressSave = false
        announced = (retentionDays, reader)
    }

    /// Writes pending changes now, then announces them to every window (their open books and
    /// trash take them) if they changed since the last announcement. The Settings window calls
    /// it when it closes; a save that didn't store announces nothing.
    public func flushSave() async {
        saveTask?.cancel()
        saveTask = nil
        guard await save() else { return }
        if let announced, announced.retentionDays == retentionDays, announced.reader == reader { return }
        announced = (retentionDays, reader)
        // `object: self` so windows (and tests) can tell this model's saves from another's.
        NotificationCenter.default.post(name: .glossSettingsChanged, object: self,
                                        userInfo: [glossReaderSettingsKey: reader])
    }

    // MARK: Internals

    private func scheduleSave() {
        generation += 1
        let token = generation
        saveTask?.cancel()
        let delay = saveDelay
        let sleep = self.sleep
        saveTask = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self, token == self.generation else { return }
            await self.save()
        }
    }

    /// Stores both settings; `false` when a write failed (nothing may be announced then: every
    /// window would apply settings that never landed, review 7).
    @discardableResult
    private func save() async -> Bool {
        saveProblem = nil
        do {
            try await services.settings.set(retentionDays, for: TrashSettings.retentionDays)
            try await ReaderSettingsStore(settings: services.settings).save(reader)
            return true
        } catch {
            saveProblem = "couldn't save your settings — try again"
            return false
        }
    }
}
