#if os(macOS)
import SwiftUI
import GlossCore
import GlossAppModel
import GlossReaderBridge

/// The reader pane: the engine for the open book's kind, drawing into the window, driven by
/// `ReaderController`, with its popovers (selection, clicked highlight, a marker's notes). Shows
/// a placeholder when there is no book, no engine for it yet, or the book didn't open.
///
/// The session host belongs to the window, not the pane: hiding the reader (notes only) and
/// showing it again re-hosts the same engine view instead of reloading the book.
public struct ReaderPane: View {
    private let reader: ReaderController
    private let engines: ReadingEngineRegistry
    private let host: ReaderSessionHost
    private let addToNotes: @MainActor () async -> Void

    public init(reader: ReaderController, engines: ReadingEngineRegistry, host: ReaderSessionHost,
                addToNotes: @escaping @MainActor () async -> Void) {
        self.reader = reader
        self.engines = engines
        self.host = host
        self.addToNotes = addToNotes
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if let session = host.session {
                ReaderHostView(session: session)
                    .id(ObjectIdentifier(session))
            }
            placeholder
            popoverAnchor
        }
        .task(id: reader.document?.kind) {
            await host.prepare(for: reader.document?.kind, engines: engines, reader: reader)
        }
    }

    /// An invisible view over the pane that carries the popover. The anchor rect is in the
    /// reader's top-left coordinates, the same space this overlay lays out in.
    @ViewBuilder private var popoverAnchor: some View {
        let presented = Binding(get: { reader.popover != nil },
                                set: { if !$0 { Task { await reader.dismissPopover() } } })
        Color.clear
            .allowsHitTesting(false)
            .popover(isPresented: presented, attachmentAnchor: .rect(.rect(anchorRect)), arrowEdge: .bottom) {
                ReaderPopoverContent(reader: reader, addToNotes: addToNotes)
            }
    }

    private var anchorRect: CGRect {
        guard let anchor = reader.popover?.anchor else { return .zero }
        return CGRect(x: anchor.x, y: anchor.y, width: max(anchor.width, 1), height: max(anchor.height, 1))
    }

    @ViewBuilder private var placeholder: some View {
        if reader.document == nil {
            ContentUnavailableView("pick a book", systemImage: "books.vertical",
                                   description: Text("choose one from the library"))
                .background(.background)
        } else if host.session == nil {
            ContentUnavailableView("gloss can't show this kind of book yet", systemImage: "doc.questionmark")
                .background(.background)
        } else if let message = reader.errorMessage, !reader.isShowingBook {
            VStack(spacing: 12) {
                ContentUnavailableView("this book wouldn't open", systemImage: "exclamationmark.triangle",
                                       description: Text(verbatim: message))
                Button("try again") { Task { await reader.retryOpen() } }
            }
            .background(.background)
        }
    }
}

/// Owns the reader's session: one per document kind, kept while the kind stays the same (and
/// while no book is open, so the next one opens in place). One per window.
@MainActor @Observable public final class ReaderSessionHost {
    public private(set) var session: (any ReaderSession)?
    private var kind: DocumentKind?

    public init() {}

    func prepare(for kind: DocumentKind?, engines: ReadingEngineRegistry, reader: ReaderController) async {
        guard let kind, kind != self.kind else { return }
        await session?.invalidate()
        // The old task is cancelled while it drains; if it resumes here, a newer prepare has
        // already run and this one must not clobber its session.
        guard !Task.isCancelled else { return }
        session = nil
        self.kind = kind
        guard let engine = engines.engine(for: kind) else { return }
        let made = engine.makeSession { [weak reader] event in
            await reader?.handle(event)
        }
        session = made
        reader.attach(made.driver)
    }
}

/// Puts an engine's view in the SwiftUI hierarchy. The view belongs to the session; the pane
/// gives each session its own identity so a new session gets a new representable.
struct ReaderHostView: NSViewRepresentable {
    let session: any ReaderSession

    func makeNSView(context: Context) -> NSView {
        session.view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
