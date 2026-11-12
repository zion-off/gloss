import GlossCore
import GlossMarkdown

/// Text selected in the notes editor.
public struct NotesSelection: Hashable, Sendable {
    public var pageID: PageID
    public var range: Range<Int>

    public init(pageID: PageID, range: Range<Int>) {
        self.pageID = pageID
        self.range = range
    }
}

/// A passage selected in the book.
public struct BookSelection: Hashable, Sendable {
    public var documentID: DocumentID
    public var passage: Passage

    public init(documentID: DocumentID, passage: Passage) {
        self.documentID = documentID
        self.passage = passage
    }
}

/// Whether "link to passage" can run, and what to tell the user when it can't.
public enum LinkGestureAvailability: Hashable, Sendable {
    case ready
    case needsBookSelection
    case needsNotesSelection
    case needsBoth
    case notLinkable

    public var isEnabled: Bool { self == .ready }

    /// Copy for the disabled command (menus show it as a tooltip, the popover inline).
    public var hint: String {
        switch self {
        case .ready: "link to passage"
        case .needsBookSelection: "now select a passage in the book"
        case .needsNotesSelection: "now select some words in your notes"
        case .needsBoth: "select words in your notes and a passage in the book"
        case .notLinkable: "links need a few words on one line, outside code"
        }
    }
}

/// The link gesture: select words in the notes and a passage in the book, in either order,
/// then "link to passage" wraps the words in a `gloss://passage/…` link. No modes.
public enum LinkGesture {
    public static func availability(notes: NotesSelection?, book: BookSelection?, document: MarkdownDocument?) -> LinkGestureAvailability {
        let hasNotes = notes.map { !$0.range.isEmpty } ?? false
        let hasBook = book.map { !$0.passage.quote.isEmpty } ?? false
        switch (hasNotes, hasBook) {
        case (false, false): return .needsBoth
        case (false, true): return .needsNotesSelection
        case (true, false): return .needsBookSelection
        case (true, true):
            guard let notes, let document, WrapInLink.canWrap(document, selection: notes.range) else { return .notLinkable }
            return .ready
        }
    }

    /// The edit that turns the notes selection into a link to `target`.
    public static func edit(in document: MarkdownDocument, selection: Range<Int>, target: LinkTargetID) -> EditResult? {
        WrapInLink(destination: GlossLink.passage(target).string).edit(document, selection: selection)
    }

    /// The edit for "add to notes" at the caret (or the end when the editor isn't focused).
    public static func quoteInsertion(of passage: Passage, target: LinkTargetID, into body: String, caret: Int?) -> QuoteInsertion.Result {
        QuoteInsertion.insert(QuoteLine.make(quote: passage.quote, target: target), into: body, at: caret)
    }
}
