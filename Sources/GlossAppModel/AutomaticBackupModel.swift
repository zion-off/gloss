import Foundation
import Observation
import GlossCore

/// Where automatic backup keeps its settings (the library's own settings table, like the rest).
public enum AutomaticBackupSettings {
    public static let enabled = SettingKey<Bool>("backup.automatic.enabled", default: false)
    /// The destination folder's path; nil until one is chosen.
    public static let folder = SettingKey<String?>("backup.automatic.folder", default: nil)
    /// When the last automatic backup succeeded (to the current folder).
    public static let lastSuccess = SettingKey<Date?>("backup.automatic.lastSuccess", default: nil)
}

/// Automatic backup of the library to one file in a folder (a day apart, quietly). It decides
/// whether a run is due and runs it through the same store snapshot as "back up library…"; the
/// Mac layer shows the settings and calls `runIfDue()` on its timer. Failures never throw: they
/// become the line under the settings toggle, and the next try is the next scheduled one.
@MainActor @Observable public final class AutomaticBackupModel {
    public private(set) var isEnabled = false
    public private(set) var folder: URL?
    public private(set) var lastSuccess: Date?
    public private(set) var isRunning = false
    /// Why the newest run failed (cleared by a success).
    public private(set) var failureReason: String?

    private let services: GlossServices
    private let activity: BackupActivity
    private let single: SingleFileBackup
    private let files: any BackupFileSystem
    private let home: URL
    /// When the newest run failed, this session only: a relaunch tries again.
    private var lastFailure: Date?

    public init(services: GlossServices, activity: BackupActivity,
                files: any BackupFileSystem = DiskBackupFileSystem(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.services = services
        self.activity = activity
        self.files = files
        self.home = home
        self.single = SingleFileBackup(files: files, ids: services.ids)
    }

    /// The folder as shown in settings ("~/Library/…").
    public var folderDisplay: String? {
        folder.map { ($0.path as NSString).abbreviatingWithTildeInPath }
    }

    /// A backup, manual or automatic, is running: "back up now" waits.
    public var isBusy: Bool { activity.isBusy || isRunning }

    /// The one line under the toggle. Quiet (nil) only when automatic backup is off and nothing
    /// has been backed up yet.
    public var statusLine: String? {
        if isRunning { return "backing up…" }
        if let failureReason { return "last backup failed: \(failureReason)" }
        if let lastSuccess { return BackupStatus.lastBackupLine(lastSuccess, now: services.time.now()) }
        return isEnabled ? "no backup yet" : nil
    }

    /// Reads what's stored. Unreadable settings leave automatic backup off.
    public func load() async {
        isEnabled = (try? await services.settings.value(AutomaticBackupSettings.enabled)) ?? false
        folder = ((try? await services.settings.value(AutomaticBackupSettings.folder)) ?? nil).map { URL(fileURLWithPath: $0, isDirectory: true) }
        lastSuccess = (try? await services.settings.value(AutomaticBackupSettings.lastSuccess)) ?? nil
    }

    /// Turns it on with the stored or default (iCloud Drive) folder. `false` means there is no
    /// folder to offer, so the person must choose one (`chooseFolder`) and it stays off.
    public func turnOn() async -> Bool {
        if folder == nil { folder = BackupFolders.defaultFolder(home: home, files: files) }
        guard folder != nil else { return false }
        isEnabled = true
        await persist()
        await runIfDue()
        return true
    }

    public func turnOff() async {
        isEnabled = false
        await persist()
    }

    /// Uses `url` as the destination. It is a new place, so the old "last backup" no longer
    /// describes it; if automatic backup is on, a backup there is due at once.
    public func setFolder(_ url: URL) async {
        folder = url
        lastSuccess = nil
        failureReason = nil
        lastFailure = nil
        await persist()
        await runIfDue()
    }

    /// `setFolder` for a person turning automatic backup on who had no folder yet.
    public func chooseFolder(_ url: URL) async {
        isEnabled = true
        await setFolder(url)
    }

    /// "back up now": the same single-file replace, right away, whether or not automatic backup
    /// is on. Needs a folder (the Mac layer asks for one first) and no other backup running.
    public func backUpNow() async {
        guard folder != nil, !isBusy else { return }
        await run()
    }

    /// Backs up now if the schedule says so (the Mac layer's timer calls this).
    public func runIfDue() async {
        guard BackupSchedule.isDue(enabled: isEnabled, hasFolder: folder != nil, lastSuccess: lastSuccess,
                                   lastFailure: lastFailure, now: services.time.now(),
                                   inProgress: isBusy) else { return }
        await run()
    }

    // MARK: Internals

    private func run() async {
        guard let folder else { return }
        isRunning = true
        activity.enter()
        defer { isRunning = false; activity.leave() }
        do {
            guard let backup = services.store as? any LibraryBackup else { throw BackupFailure.unsupported }
            let verifier = services.store as? any BackupVerifying
            let single = single
            // Off the main actor: copying a big library must not stall the UI.
            _ = try await Task.detached(priority: .utility) {
                try await single.run(in: folder, snapshot: { try await backup.backup(to: $0) },
                                     verify: { url in if let verifier { try await verifier.verifyBackup(at: url) } })
            }.value
            let now = services.time.now()
            lastSuccess = now
            failureReason = nil
            lastFailure = nil
            try? await services.settings.set(now, for: AutomaticBackupSettings.lastSuccess)
        } catch is CancellationError {
            // The app is quitting or the task ended: not a failure to report.
        } catch {
            failureReason = (error as? BackupFailure)?.reason ?? "couldn't write to the folder"
            lastFailure = services.time.now()
        }
    }

    private func persist() async {
        let settings = services.settings
        try? await settings.set(isEnabled, for: AutomaticBackupSettings.enabled)
        try? await settings.set(folder?.path, for: AutomaticBackupSettings.folder)
        try? await settings.set(lastSuccess, for: AutomaticBackupSettings.lastSuccess)
    }
}
