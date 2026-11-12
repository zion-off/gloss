import Foundation

/// Delivers engine events one at a time, in the order they arrived.
///
/// Engines report events synchronously (a WebKit script message, a PDFKit notification), but
/// handling one is async: `ReaderController` may send a command and wait for the engine
/// before it is done. Without a queue a `relocated` could be handled in the middle of the
/// `opened` before it. Every engine session posts into its own inbox and closes it when the
/// session ends.
@MainActor public final class ReaderEventInbox {
    private let continuation: AsyncStream<ReaderEngineEvent>.Continuation
    private let worker: Task<Void, Never>

    public init(deliver: @escaping @MainActor @Sendable (ReaderEngineEvent) async -> Void) {
        let (stream, continuation) = AsyncStream<ReaderEngineEvent>.makeStream()
        self.continuation = continuation
        worker = Task { @MainActor in
            for await event in stream {
                await deliver(event)
            }
        }
    }

    deinit {
        continuation.finish()
    }

    /// Queues an event. Events posted after `close()` are dropped.
    public func post(_ event: ReaderEngineEvent) {
        continuation.yield(event)
    }

    /// Stops taking events; the ones already queued are still delivered.
    public func close() {
        continuation.finish()
    }

    /// Closes the inbox and waits until every queued event was delivered.
    public func closeAndDrain() async {
        continuation.finish()
        await worker.value
    }
}
