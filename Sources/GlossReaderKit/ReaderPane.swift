#if os(macOS)
import SwiftUI
import GlossCore
import GlossAppModel
import GlossReaderBridge

/// The reader pane: the engine for the open book's kind, drawing into the window, driven by
/// `ReaderController`. Shows a placeholder when there is no book, no engine for it yet, or the
/// book didn't open.
public struct ReaderPane: View {
    private let reader: ReaderController
    private let engines: ReadingEngineRegistry
    @State private var host = ReaderSessionHost()

    public init(reader: ReaderController, engines: ReadingEngineRegistry) {
        self.reader = reader
        self.engines = engines
    }

    public var body: some View {
        ZStack {
            if let session = host.session {
                ReaderHostView(session: session)
                    .id(ObjectIdentifier(session))
            }
            placeholder
        }
        .task(id: reader.document?.kind) {
            host.prepare(for: reader.document?.kind, engines: engines, reader: reader)
        }
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

/// Owns the pane's session: one per document kind, kept while the kind stays the same (and
/// while no book is open, so the next one opens in place).
@MainActor @Observable final class ReaderSessionHost {
    private(set) var session: (any ReaderSession)?
    private var kind: DocumentKind?

    func prepare(for kind: DocumentKind?, engines: ReadingEngineRegistry, reader: ReaderController) {
        guard let kind, kind != self.kind else { return }
        session?.invalidate()
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
