import Foundation
import GlossCore
import GlossMarkdown
import GlossNotes

/// The link gesture and "add to notes", across the two panes. Returns edits for the editor to
/// apply (so they are undoable there); when the notes aren't open in an editor, writes directly.
@MainActor public struct LinkingCoordinator {
    let services: GlossServices
    let reader: ReaderController

    public init(services: GlossServices, reader: ReaderController) {
        self.services = services
        self.reader = reader
    }

    /// Whether "link to passage" can run, and the hint to show when it can't.
    public func availability(notes: NotesSelection?, document: MarkdownDocument?) -> LinkGestureAvailability {
        LinkGesture.availability(notes: notes, book: reader.selection, document: document)
    }

    /// Links the notes selection to the book selection. The editor applies the returned edit
    /// and saves; call `didSaveLinkedPage()` afterwards so the marker appears.
    public func linkToPassage(notes: NotesSelection?, document: MarkdownDocument) async throws -> EditResult {
        let available = availability(notes: notes, document: document)
        guard available.isEnabled, let book = reader.selection, let notes else {
            throw GlossError.notAllowed(available.hint)
        }
        let target = try await services.links.target(for: book.passage, in: book.documentID)
        guard let edit = LinkGesture.edit(in: document, selection: notes.range, target: target.id) else {
            throw GlossError.notAllowed(LinkGestureAvailability.notLinkable.hint)
        }
        return edit
    }

    /// The quote line for "add to notes" at the editor's caret (nil caret: end of page).
    public func quoteInsertion(into body: String, caret: Int?) async throws -> (QuoteInsertion.Result, LinkTarget) {
        guard let book = reader.selection else { throw GlossError.notAllowed("select a passage in the book first") }
        let target = try await services.links.target(for: book.passage, in: book.documentID)
        return (LinkGesture.quoteInsertion(of: book.passage, target: target.id, into: body, caret: caret), target)
    }

    /// "add to notes" when no editor has the page open: writes the quote line at the end.
    @discardableResult
    public func addSelectionToNotes(page: PageID) async throws -> Page {
        guard let book = reader.selection else { throw GlossError.notAllowed("select a passage in the book first") }
        let (saved, _, _) = try await services.links.addQuote(of: book.passage, in: book.documentID, to: page)
        await reader.refreshAnnotations()
        return saved
    }

    /// Redraws markers after a page with a new or removed link was saved.
    public func didSaveLinkedPage() async {
        await reader.refreshAnnotations()
    }
}
