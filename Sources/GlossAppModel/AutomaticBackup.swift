import Foundation
import Observation
import GlossCore

/// What the single-file backup asks of the file system, and nothing more.
public protocol BackupFileSystem: Sendable {
    func isDirectory(at url: URL) -> Bool
    func fileNames(in folder: URL) throws -> [String]
    func createDirectory(at url: URL) throws
    func remove(at url: URL) throws
    /// Makes `destination` hold `source`'s content in one step (`source` is gone afterwards).
    /// An existing `destination` is replaced atomically, never removed first.
    func replace(_ destination: URL, with source: URL) throws
}

/// The real file system.
public struct DiskBackupFileSystem: BackupFileSystem {
    public init() {}

    public func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func fileNames(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func remove(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func replace(_ destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }
}

/// Why an automatic run didn't produce a backup, in words for the settings line.
public enum BackupFailure: Error, Equatable, Sendable {
    case folderMissing
    case verifyFailed
    case unsupported

    public var reason: String {
        switch self {
        case .folderMissing: "the folder isn't there"
        case .verifyFailed: "the copy didn't check out"
        case .unsupported: "this library can't be backed up"
        }
    }
}

/// Keeps exactly one backup file in a folder: each run writes the snapshot to a temporary file
/// beside it, verifies it, then replaces the file in one step, so the last good backup survives
/// any failure and no temporary file is left behind.
public struct SingleFileBackup: Sendable {
    static let temporaryPrefix = ".gloss-backup-"
    static let temporarySuffix = ".partial"

    private let files: any BackupFileSystem
    private let ids: any IDGenerator

    public init(files: any BackupFileSystem = DiskBackupFileSystem(), ids: any IDGenerator = UUIDv7Generator()) {
        self.files = files
        self.ids = ids
    }

    /// - Parameters:
    ///   - snapshot: writes a copy of the library to the (not yet existing) url it is given.
    ///   - verify: throws when that copy isn't sound.
    /// - Returns: the backup file's url.
    @discardableResult
    public func run(in folder: URL,
                    snapshot: @Sendable (URL) async throws -> Void,
                    verify: @Sendable (URL) async throws -> Void) async throws -> URL {
        guard files.isDirectory(at: folder) else { throw BackupFailure.folderMissing }
        removeStaleTemporaries(in: folder)
        let temporary = folder.appendingPathComponent("\(Self.temporaryPrefix)\(ids.next().stringValue)\(Self.temporarySuffix)")
        let destination = folder.appendingPathComponent(LibraryBackupNaming.automaticFileName)
        do {
            try await snapshot(temporary)
            do { try await verify(temporary) } catch is CancellationError { throw CancellationError() } catch { throw BackupFailure.verifyFailed }
            try files.replace(destination, with: temporary)
        } catch {
            try? files.remove(at: temporary)
            throw error
        }
        return destination
    }

    /// Temporary files a crashed run left behind.
    private func removeStaleTemporaries(in folder: URL) {
        for name in (try? files.fileNames(in: folder)) ?? []
        where name.hasPrefix(Self.temporaryPrefix) && name.hasSuffix(Self.temporarySuffix) {
            try? files.remove(at: folder.appendingPathComponent(name))
        }
    }
}

/// "Is a backup due?", as one pure decision.
public enum BackupSchedule {
    /// A day between backups.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// Due when automatic backup is on with a folder, nothing else is backing up, and the newest
    /// attempt (a success or a failure this session) is a day old. A failure counts so that a
    /// broken folder is tried once a day, not every check. A clock set back makes it due.
    public static func isDue(enabled: Bool, hasFolder: Bool, lastSuccess: Date?, lastFailure: Date?,
                             now: Date, inProgress: Bool) -> Bool {
        guard enabled, hasFolder, !inProgress else { return false }
        guard let last = [lastSuccess, lastFailure].compactMap({ $0 }).max() else { return true }
        let age = now.timeIntervalSince(last)
        return age >= interval || age < 0
    }
}

/// Counts the backups under way in this process (manual and automatic), so an automatic run
/// doesn't start on top of one.
@MainActor @Observable public final class BackupActivity {
    private var running = 0

    public init() {}

    public var isBusy: Bool { running > 0 }

    public func enter() { running += 1 }

    public func leave() { running = max(0, running - 1) }
}

/// Where automatic backup goes unless the person picks a folder.
public enum BackupFolders {
    /// `gloss` inside iCloud Drive, created if needed; nil when iCloud Drive isn't there.
    public static func defaultFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                     files: any BackupFileSystem = DiskBackupFileSystem()) -> URL? {
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard files.isDirectory(at: drive) else { return nil }
        let folder = drive.appendingPathComponent("gloss", isDirectory: true)
        if !files.isDirectory(at: folder) {
            do { try files.createDirectory(at: folder) } catch { return nil }
        }
        return folder
    }
}

/// The settings line under the toggle.
public enum BackupStatus {
    /// "last backup: today 2:02 pm", "yesterday …", or "nov 12, 2:02 pm" — lowercase like the rest.
    public static func lastBackupLine(_ date: Date, now: Date, calendar: Calendar = .current,
                                      locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = locale
        time.timeStyle = .short
        time.dateStyle = .none
        let clock = time.string(from: date)
        let when: String
        if calendar.isDate(date, inSameDayAs: now) {
            when = "today \(clock)"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            when = "yesterday \(clock)"
        } else {
            let day = DateFormatter()
            day.calendar = calendar
            day.timeZone = calendar.timeZone
            day.locale = locale
            day.setLocalizedDateFormatFromTemplate("MMMd")
            when = "\(day.string(from: date)), \(clock)"
        }
        return "last backup: \(when)".lowercased()
    }
}
