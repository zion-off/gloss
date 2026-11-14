import Foundation
import Observation
import GlossCore

/// The "back up library…" flow's portable half: the never-overwrite rule, the copy
/// running off the main actor, and the result the window reports. The save panel is the Mac
/// layer's; this model takes the chosen url.
@MainActor @Observable public final class BackupModel {
    public enum State: Equatable, Sendable {
        case idle
        case running
        case done(URL)
        case failed(String)
    }

    public private(set) var state: State = .idle

    private let backup: (any LibraryBackup)?

    public init(services: GlossServices) {
        // The composition root wires the capability; a store without it (none in practice)
        // makes the command explain itself instead of failing silently.
        self.backup = services.store as? any LibraryBackup
    }

    public var canBackUp: Bool { backup != nil }

    /// Copies the library to `url`, which must not exist: gloss never overwrites a backup
    /// (the store refuses too; this check keeps the message friendly and the file untouched).
    public func backUp(to url: URL) async {
        guard let backup else {
            state = .failed("this library can't be backed up")
            return
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            state = .failed("\(url.lastPathComponent) already exists — pick another name, gloss never overwrites a backup")
            return
        }
        state = .running
        do {
            // Off the main actor: a big library must not stall the UI (brief 36's rule for
            // import applies to any long read of the store).
            try await Task.detached(priority: .userInitiated) {
                try await backup.backup(to: url)
            }.value
            state = .done(url)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    /// The report was acknowledged; back to quiet.
    public func clearResult() {
        state = .idle
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as GlossError: error.description
        case StoreError.conflict: "that file already exists — gloss never overwrites a backup"
        default: "couldn't write the backup — check the disk and try again"
        }
    }
}
