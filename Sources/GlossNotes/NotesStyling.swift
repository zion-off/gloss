import GlossCore
import GlossMarkdown

/// Style roles the notes layer adds on top of plain markdown.
public enum NotesRole {
    public static let passageLink = StyleRole("passageLink")
    public static let pageLink = StyleRole("pageLink")
    public static let bookLink = StyleRole("bookLink")
    /// A gloss link whose destination is in the trash.
    public static let trashedLink = StyleRole("trashedLink")
    /// A gloss link whose destination no longer exists.
    public static let brokenLink = StyleRole("brokenLink")
    /// A line drawn as a subpage row instead of text.
    public static let subpageBlock = StyleRole("subpageBlock")
}

/// Whether a link's destination exists right now (filled in by the app from the store).
public enum LinkStatus: Hashable, Sendable {
    case live, inTrash, missing
}

/// Styling for a notes page: standard markdown rules plus `gloss://` link classification
/// and subpage rows, all as presentation over the untouched text.
public struct NotesStyler: Sendable {
    public var rules: StyleRuleSet
    public var statuses: [GlossLink: LinkStatus]

    public init(rules: StyleRuleSet = .standard, statuses: [GlossLink: LinkStatus] = [:]) {
        self.rules = rules
        self.statuses = statuses
        self.rules.decorators.append(GlossLinkDecorator(statuses: statuses))
    }

    public func spans(for document: MarkdownDocument, subpageRows: [SubpageRow] = []) -> [StyleSpan] {
        rules.spans(for: document) + subpageRows.map { StyleSpan(range: $0.lineRange, role: NotesRole.subpageBlock) }
    }

    /// The links on a page whose status the app should look up.
    public static func glossLinks(in document: MarkdownDocument) -> Set<GlossLink> {
        Set(LinkScanner.links(in: document).compactMap { GlossLink(string: $0.destination) })
    }
}

struct GlossLinkDecorator: StylingRule {
    let statuses: [GlossLink: LinkStatus]

    func spans(for inline: Inline, in text: MarkdownText) -> [StyleSpan] {
        guard inline.kind == .link || inline.kind == .autolink, let destination = inline.destination,
              let link = GlossLink(string: destination) else { return [] }
        let role: StyleRole
        switch statuses[link] ?? .live {
        case .missing: role = NotesRole.brokenLink
        case .inTrash: role = NotesRole.trashedLink
        case .live:
            switch link {
            case .passage: role = NotesRole.passageLink
            case .page: role = NotesRole.pageLink
            case .document: role = NotesRole.bookLink
            }
        }
        return [StyleSpan(range: inline.contentRange, role: role)]
    }
}

/// A subpage block row to draw in place of its marker line.
public struct SubpageRow: Hashable, Sendable {
    public var lineRange: Range<Int>
    public var pageID: PageID
    /// The page's current title (live, not the label in the text).
    public var title: String
    public var isTrashed: Bool
}

public enum SubpageRows {
    /// The row covering a paragraph's range, if any. TextKit 2 may or may not include the
    /// paragraph's line terminator in the element range (unverifiable off a Mac), so this
    /// matches by overlap, which is correct either way (review 5).
    public static func row(covering paragraphRange: Range<Int>, in rows: [SubpageRow]) -> SubpageRow? {
        let range = paragraphRange.lowerBound..<max(paragraphRange.lowerBound, paragraphRange.upperBound)
        return rows.first { $0.lineRange.overlaps(range) }
    }

    /// Rows for block lines that point at children of the page being edited. Lines pointing
    /// elsewhere stay ordinary links.
    public static func rows(in document: MarkdownDocument, children: [Page]) -> [SubpageRow] {
        let byID = Dictionary(children.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return PageBlockLines.find(in: document).compactMap { line in
            guard let child = byID[line.pageID] else { return nil }
            return SubpageRow(lineRange: line.lineRange, pageID: child.id,
                              title: child.title.isEmpty ? PageService.untitled : child.title, isTrashed: child.trash != nil)
        }
    }
}
