import Foundation
import Observation
import GlossCore

/// The undo toast after something moved to the trash: what the capsule says, and
/// the entry "undo" restores. A failure to trash is the same shape with no entry.
public struct TrashToast: Equatable, Sendable {
    public var message: String
    /// The entry to restore; nil when the toast only reports why nothing was trashed.
    public var entry: TrashEntry?

    public init(message: String, entry: TrashEntry?) {
        self.message = message
        self.entry = entry
    }
}

/// Moving things to the trash, with the undo toast. `AppModel` orchestrates what the
/// window does afterwards; this model owns the toast and the service call.
///
/// The toast goes away on its own after `dismissDelay`, or when a newer one replaces it. Time
/// is injected (`sleep`) so tests dismiss deterministically; `flushToastDismissal` waits for
/// the pending dismissal.
@MainActor @Observable public final class DeletionModel {
    public private(set) var toast: TrashToast?

    private let services: GlossServices
    private let dismissDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var dismissTask: Task<Void, Never>?
    /// Bumped by every toast; only the newest may dismiss.
    private var generation = 0

    public init(services: GlossServices,
                dismissDelay: Duration = .seconds(6),
                sleep: @escaping @Sendable (Duration) async throws -> Void = taskSleep) {
        self.services = services
        self.dismissDelay = dismissDelay
        self.sleep = sleep
    }

    /// Moves an entity (and its cascade) to the trash and shows the undo toast. Returns the
    /// entry it created, or nil when it couldn't be trashed — the toast then says why.
    @discardableResult
    public func trash(kind: TrashableKind, id: String) async -> TrashEntry? {
        do {
            let entry = try await services.trash.trash(kind, id: id)
            publish(TrashToast(message: "“\(entry.title)” moved to the trash", entry: entry))
            return entry
        } catch {
            publish(TrashToast(message: Self.describe(error), entry: nil))
            return nil
        }
    }

    /// Restores an entry's whole batch. Returns what came back, or nil when it was
    /// already gone (restored twice, purged from the cli, …). A matching toast goes with it.
    public func undo(_ entry: TrashEntry) async -> [TrashEntry]? {
        do {
            let restored = try await services.trash.restore(entry.id)
            if toast?.entry?.id == entry.id { clearToast() }
            return restored
        } catch {
            // The entry was purged from the cli between the toast and its undo, or the read
            // failed: say so instead of leaving a dead Undo button on screen.
            publish(TrashToast(message: "couldn't put it back — it may have gone for good", entry: nil))
            return nil
        }
    }

    /// Takes the toast away now (its undo stays registered with the window's undo manager).
    public func dismissToast() {
        clearToast()
    }

    /// A toast that only says something went wrong (the page vanished before the click landed).
    public func reportFailure(_ message: String) {
        publish(TrashToast(message: message, entry: nil))
    }

    /// Waits for the pending auto-dismissal (tests, and teardown before quit).
    public func flushToastDismissal() async {
        while let task = dismissTask {
            await task.value
            if dismissTask == task { break }
        }
    }

    // MARK: Internals

    private func clearToast() {
        generation += 1  // any pending dismissal is stale now
        dismissTask?.cancel()
        dismissTask = nil
        toast = nil
    }

    private func publish(_ newToast: TrashToast) {
        generation += 1
        let token = generation
        toast = newToast
        dismissTask?.cancel()
        let delay = dismissDelay
        let sleep = self.sleep
        dismissTask = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self, token == self.generation else { return }
            self.toast = nil
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as GlossError: error.description
        default: "couldn't move it to the trash"
        }
    }
}
