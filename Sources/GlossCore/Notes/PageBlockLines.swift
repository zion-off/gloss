import GlossMarkdown

/// A line in a page body that consists only of a link to another page — the marker for where
/// a subpage renders as a block row.
public struct PageBlockLine: Hashable, Sendable {
    public var pageID: PageID
    /// The whole line (no newline).
    public var lineRange: Range<Int>
    public var linkRange: Range<Int>
    public var labelRange: Range<Int>
    public var label: String
}

public enum PageBlockLines {
    public static func find(in body: String, parser: MarkdownParser = .standard) -> [PageBlockLine] {
        find(in: parser.parse(body))
    }

    public static func find(in document: MarkdownDocument) -> [PageBlockLine] {
        document.blocks.compactMap { block in
            guard block.kind == .paragraph, block.inlines.count == 1, let link = block.inlines.first,
                  link.kind == .link, let destination = link.destination,
                  case .page(let pageID) = GlossLink(string: destination) else { return nil }
            // Only whitespace may surround the link.
            let text = document.text
            guard text.isBlank(block.range.lowerBound..<link.range.lowerBound),
                  text.isBlank(link.range.upperBound..<block.range.upperBound) else { return nil }
            return PageBlockLine(pageID: pageID, lineRange: block.range, linkRange: link.range,
                                 labelRange: link.contentRange, label: text[link.contentRange])
        }
    }

    /// The markdown line that places `page` as a block in its parent.
    public static func line(for pageID: PageID, title: String) -> String {
        "[\(MarkdownEscaping.escapeLinkLabel(title.isEmpty ? PageService.untitled : title))](\(GlossLink.page(pageID).string))"
    }
}

/// Builds the quote line "add to notes" inserts: `> the quote [↗](gloss://passage/<id>)`.
public enum QuoteLine {
    public static let arrow = "↗"

    public static func make(quote: String, target: LinkTargetID) -> String {
        let text = MarkdownEscaping.escapeInline(Passage.normalize(quote))
        return "> \(text) [\(arrow)](\(GlossLink.passage(target).string))"
    }
}

/// Extracts what a page links to, for reference tracking.
public enum ReferenceExtractor {
    public static func references(in body: String, parser: MarkdownParser = .standard) -> Set<ReferenceTarget> {
        Set(LinkScanner.links(in: parser.parse(body)).compactMap { GlossLink(string: $0.destination)?.referenceTarget })
    }
}
