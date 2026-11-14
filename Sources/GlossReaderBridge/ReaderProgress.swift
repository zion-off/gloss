import Foundation
import GlossCore
import GlossEPUB

/// Human-readable reading progress, like Apple Books.
public enum ReaderProgressText {
    /// "3 pages left in chapter 3" / "the end" / "28% in".
    public static func describe(_ payload: ReaderRelocatedPayload) -> String {
        if payload.atEnd { return "the end" }
        if let left = payload.pagesLeftInSection, left > 0 {
            let trimmed = payload.tocLabel?.trimmingCharacters(in: .whitespaces) ?? ""
            let where_ = trimmed.isEmpty ? "section \(payload.section.index + 1)" : trimmed
            return "\(left) \(left == 1 ? "page" : "pages") left in \(where_)"
        }
        if payload.atStart { return "the start" }
        return "\(Int((payload.fraction * 100).rounded()))% in"
    }
}

/// Bridges reader events into core values, so the Mac layer stays thin.
public enum ReaderEventMapping {
    /// A passage the user selected in the book.
    public static func passage(from selection: ReaderSelectionChangedPayload) -> Passage {
        Passage(locator: Locator(scheme: EPUBLocators.cfiScheme, value: selection.cfi),
                quote: selection.text, label: selection.label, progression: selection.fraction)
    }

    /// The reading position to remember.
    public static func readingPosition(from relocated: ReaderRelocatedPayload, of documentID: DocumentID, updatedAt: Date) -> ReadingPosition {
        ReadingPosition(documentID: documentID,
                        locator: Locator(scheme: EPUBLocators.cfiScheme, value: relocated.cfi),
                        progression: relocated.fraction,
                        label: progressLabel(of: relocated),
                        updatedAt: updatedAt)
    }

    /// "Chapter 1. Loomings · page 12" (the toc label and the print page label, when the book
    /// has them) for breadcrumbs and the saved position.
    public static func progressLabel(of relocated: ReaderRelocatedPayload) -> String? {
        var parts: [String] = []
        if let label = relocated.tocLabel, !label.isEmpty { parts.append(label) }
        else if relocated.section.count > 1 { parts.append("section \(relocated.section.index + 1)") }
        if let page = relocated.pageLabel, !page.isEmpty { parts.append(page) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}
