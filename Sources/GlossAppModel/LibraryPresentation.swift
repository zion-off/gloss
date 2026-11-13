import Foundation
import Observation
import GlossCore

/// One window's library presentation state: what the window-level library UI is showing. Views
/// set it (context menus, the File › import command through `@FocusedValue`); the window's
/// `libraryFeatures` modifier presents from it. No logic lives here — it is a switchboard.
@MainActor @Observable public final class LibraryPresentationModel {
    /// The document whose details sheet is showing (nil = none). Set from the grid's and the
    /// source list's "edit details…" commands.
    public var detailsDocument: DocumentID?
    /// Whether the import panel should show (File › import…, the empty state's button).
    public var showsImportPanel = false
    /// Whether a file drag is over the window (the grid draws its drop highlight).
    public var dropTargeted = false
    /// The import news to offer once an import ends (nil = nothing to say).
    public var importNews: ImportSummary?

    public init() {}
}

extension AppModel {
    /// After a document's details (title, author, cover) changed: reload every pane that shows
    /// them — the grid and its cover cache, the workspace's copy of the document and page (the
    /// window title and the source list read it), the notes editor when the renamed book is the
    /// one open, and the book's sidebar tree.
    public func refreshAfterDetailsEdit(of id: DocumentID) async {
        await library.invalidate(ids: [id])
        await workspace.refresh()
        if notes.page?.documentID == id { await notes.pageChangedExternally() }
        await showBookSidebar()
    }
}
