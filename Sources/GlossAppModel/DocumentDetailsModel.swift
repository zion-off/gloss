import Foundation
import Observation
import GlossCore

/// The details sheet's editable fields, with the rules the sheet enforces: the title
/// is trimmed and may not end up empty; only fields that actually changed are written.
public struct DetailsDraft: Equatable, Sendable {
    public var title: String
    public var author: String

    public init(document: Document) {
        title = document.title
        author = document.author
    }

    public init(title: String, author: String) {
        self.title = title
        self.author = author
    }

    /// The title as it would be saved.
    public var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The author as it would be saved.
    public var trimmedAuthor: String { author.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A book must keep a name; the author may be empty.
    public var isValid: Bool { !trimmedTitle.isEmpty }

    /// What the sheet tells the user about an empty title.
    public var titleProblem: String? { isValid ? nil : "a book needs a name" }

    /// Only the fields that changed, in the shape `LibraryService.updateDetails` wants, so an
    /// untouched field is never written (and never marks the document updated). An emptied
    /// title is refused here too: it never reaches the store.
    public func changes(from document: Document) -> (title: String?, author: String?) {
        let title = trimmedTitle != document.title && !trimmedTitle.isEmpty ? trimmedTitle : nil
        let author = trimmedAuthor != document.author ? trimmedAuthor : nil
        return (title, author)
    }
}

/// The details sheet's state: the draft, the cover the user is choosing, and the save itself.
/// The Mac sheet renders this and forwards events; every rule is here, Linux-tested.
@MainActor @Observable public final class DocumentDetailsModel {
    /// What the sheet should do with the cover on save.
    public enum CoverEdit: Equatable, Sendable {
        /// Leave the cover alone.
        case unchanged
        /// Set a custom cover from these image bytes.
        case set(Data)
        /// Drop the custom cover and go back to the file's, or a generated one.
        case remove
    }

    public var draft: DetailsDraft
    /// The document as it stands in the store (the draft is compared against it).
    public private(set) var document: Document
    public private(set) var cover: CoverEdit = .unchanged
    /// Why the chosen cover was refused (cleared by the next choice).
    public private(set) var coverProblem: String?
    /// Why the save failed, if it did.
    public private(set) var saveProblem: String?

    private let services: GlossServices

    public init(services: GlossServices, document: Document) {
        self.services = services
        self.document = document
        self.draft = DetailsDraft(document: document)
    }

    public var isValid: Bool { draft.isValid }

    /// What the sheet tells the user about an emptied title.
    public var titleProblem: String? { draft.titleProblem }

    /// Whether anything in the sheet would change the document.
    public var hasChanges: Bool {
        let changes = draft.changes(from: document)
        return changes.title != nil || changes.author != nil || cover != .unchanged
    }

    /// Whether the sheet offers removing the custom cover: one exists, or a new image is
    /// pending (removing then just drops the pending choice).
    public var showsRemoveCover: Bool {
        if case .set = cover { return true }
        return document.coverHash != nil
    }

    /// A cover image the user picked or dropped: read off the main actor, and only image bytes
    /// are accepted (anything else is refused with a reason).
    public func chooseCover(from url: URL) async {
        let data: Data? = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        guard let data, !data.isEmpty else {
            coverProblem = "couldn't read \(url.lastPathComponent)"
            return
        }
        guard CoverImage.sniffMimeType(data).hasPrefix("image/") else {
            coverProblem = "that file isn't an image"
            return
        }
        coverProblem = nil
        cover = .set(data)
    }

    /// Back to the file's cover (or a generated one) on save.
    public func removeCover() {
        coverProblem = nil
        cover = .remove
    }

    /// Writes what changed: the fields that differ, then the cover. Returns false only when
    /// the draft is invalid or the store refused; a valid draft with nothing to write is a
    /// no-op that still succeeds (so Save can close the sheet).
    @discardableResult
    public func save() async -> Bool {
        saveProblem = nil
        guard isValid else { return false }
        let changes = draft.changes(from: document)
        guard changes.title != nil || changes.author != nil || cover != .unchanged else { return true }
        do {
            if changes.title != nil || changes.author != nil {
                document = try await services.library.updateDetails(document.id, title: changes.title, author: changes.author)
            }
            switch cover {
            case .unchanged: break
            case .set(let data): document = try await services.library.setCover(document.id, imageData: data)
            case .remove: document = try await services.library.setCover(document.id, imageData: nil)
            }
            cover = .unchanged
            return true
        } catch {
            saveProblem = (error as? GlossError)?.description ?? "something went wrong"
            return false
        }
    }
}
