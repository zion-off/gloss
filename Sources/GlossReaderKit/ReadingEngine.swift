#if os(macOS)
import AppKit
import GlossCore
import GlossReaderBridge

/// One engine's live reader: the view it draws in and the commands it takes. The EPUB engine
/// keeps one session for every EPUB (books switch in place, D-080); the pane makes a new session
/// only when the kind of document changes.
@MainActor
public protocol ReaderSession: AnyObject {
    var view: NSView { get }
    var driver: any ReaderDriving { get }
    /// Stops delivering events and waits until the queued ones were delivered, so nothing from
    /// this session lands after the next one is attached (review 4).
    func invalidate() async
}

/// Makes reader sessions for the document kinds it reads (open/closed: a new engine is
/// registered, never wired in by branching on a kind).
@MainActor
public protocol ReadingEngine {
    var kinds: Set<DocumentKind> { get }
    /// `deliver` receives the session's events one at a time, in order (`ReaderEventInbox`).
    func makeSession(deliver: @escaping @MainActor @Sendable (ReaderEngineEvent) async -> Void) -> any ReaderSession
}

/// The registered engines. Composition roots build one.
@MainActor
public struct ReadingEngineRegistry {
    private let engines: [any ReadingEngine]

    public init(_ engines: [any ReadingEngine]) {
        self.engines = engines
    }

    public func engine(for kind: DocumentKind) -> (any ReadingEngine)? {
        engines.first { $0.kinds.contains(kind) }
    }
}
#endif
