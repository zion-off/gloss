import AppKit
import GlossCore
import GlossReaderBridge

/// One engine's live reader: the view it draws in and the commands it takes. The EPUB engine
/// keeps one session for every EPUB (books switch in place); the pane makes a new session
/// only when the kind of document changes.
///
/// Every session must post `.ready` once it can take commands: `ReaderController` holds back
/// `open` until it hears it, and `attach` forgets an earlier one. The EPUB session's `ready`
/// comes from the page; an engine with nothing to load posts it as soon as it is built. Without
/// it a book never opens and the pane stays blank.
@MainActor
public protocol ReaderSession: AnyObject {
    var view: NSView { get }
    var driver: any ReaderDriving { get }
    /// What the book is drawn on in the current theme (an EPUB's page, the space around a PDF's
    /// pages): the pane shows it while a book opens, so the wait looks like blank paper.
    var pageColor: NSColor { get }
    /// Stops delivering events and waits until the queued ones were delivered, so nothing from
    /// this session lands after the next one is attached.
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
