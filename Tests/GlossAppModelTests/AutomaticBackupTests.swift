import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossTestSupport

@Suite("automatic backup")
struct AutomaticBackupTests {
    /// A folder as a dictionary of names to content; can be told to fail the replace.
    final class Folder: BackupFileSystem, @unchecked Sendable {
        var files: [String: String] = [:]
        var directoryExists = true
        var failReplace = false
        struct Failure: Error {}
        func isDirectory(at url: URL) -> Bool { directoryExists }
        func fileNames(in folder: URL) throws -> [String] { Array(files.keys) }
        func createDirectory(at url: URL) throws {}
        func remove(at url: URL) throws { files[url.lastPathComponent] = nil }
        func replace(_ destination: URL, with source: URL) throws {
            if failReplace { throw Failure() }
            files[destination.lastPathComponent] = files.removeValue(forKey: source.lastPathComponent)
        }
    }

    static let folder = URL(fileURLWithPath: "/backups", isDirectory: true)
    static let name = LibraryBackupNaming.automaticFileName
    let disk = Folder()

    func run(snapshot: String = "new", verify: @escaping @Sendable (URL) async throws -> Void = { _ in }) async throws {
        let disk = disk
        try await SingleFileBackup(files: disk, ids: SequentialIDGenerator()).run(
            in: Self.folder, snapshot: { disk.files[$0.lastPathComponent] = snapshot }, verify: verify)
    }

    @Test("due: on, with a folder, idle, and a day since the last success; a failure waits its day too")
    func due() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), day = BackupSchedule.interval
        func due(enabled: Bool = true, folder: Bool = true, success: TimeInterval? = nil, failure: TimeInterval? = nil,
                 busy: Bool = false) -> Bool {
            BackupSchedule.isDue(enabled: enabled, hasFolder: folder, lastSuccess: success.map { now.addingTimeInterval(-$0) },
                                 lastFailure: failure.map { now.addingTimeInterval(-$0) }, now: now, inProgress: busy)
        }
        #expect(due())  // never backed up
        #expect(due(success: day))
        #expect(!due(success: day - 1))
        #expect(!due(enabled: false) && !due(folder: false) && !due(busy: true))
        #expect(!due(success: 2 * day, failure: 60))  // a failed try an hour ago is not retried yet
        #expect(due(success: 3 * day, failure: day))
        #expect(due(success: -60))  // a clock set back
    }

    @Test("the single file is replaced, never duplicated, and a failed run keeps the last good one")
    func replaces() async throws {
        try await run(snapshot: "first")
        try await run(snapshot: "second")
        #expect(disk.files == [Self.name: "second"])

        // Verify fails: the old file stays, the temporary one goes.
        struct Bad: Error {}
        await #expect(throws: BackupFailure.verifyFailed) { try await run(snapshot: "corrupt", verify: { _ in throw Bad() }) }
        #expect(disk.files == [Self.name: "second"])

        disk.failReplace = true
        await #expect(throws: Folder.Failure.self) { try await run(snapshot: "third") }
        #expect(disk.files == [Self.name: "second"])

        disk.directoryExists = false
        await #expect(throws: BackupFailure.folderMissing) { try await run() }
    }

    @Test("stale temporaries from a crashed run are cleaned; other files are left alone")
    func cleansStale() async throws {
        disk.files = [".gloss-backup-old.partial": "half", "notes.txt": "mine", Self.name: "good"]
        try await run(snapshot: "fresh")
        #expect(disk.files == [Self.name: "fresh", "notes.txt": "mine"])
    }

    @MainActor @Test("back up now works while off, shows the line, and waits for a running backup")
    func backUpNow() async throws {
        let lib = TestLibrary()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-auto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = BackupActivity()
        let model = AutomaticBackupModel(services: lib.services, activity: activity)
        #expect(model.statusLine == nil)

        await model.setFolder(directory)  // off: nothing runs
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

        activity.enter()
        await model.backUpNow()  // another backup is running
        #expect(model.statusLine == nil)
        activity.leave()

        await model.backUpNow()
        await model.backUpNow()  // replaces
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [Self.name])
        #expect(model.statusLine?.hasPrefix("last backup: today") == true)

        try FileManager.default.removeItem(at: directory)
        await model.backUpNow()
        #expect(model.statusLine == "last backup failed: the folder isn't there")
    }
}
