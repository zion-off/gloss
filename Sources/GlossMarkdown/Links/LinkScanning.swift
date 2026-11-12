/// A link found in markdown text.
public struct MarkdownLink: Hashable, Sendable {
    public var range: Range<Int>
    public var labelRange: Range<Int>
    /// The label as written (may contain markdown).
    public var label: String
    public var destination: String
    public var destinationRange: Range<Int>

    /// The label without markdown syntax, for display.
    public var plainLabel: String { PlainText.strip(label) }
}

/// Finds and rewrites links. Code spans and code blocks never contain links.
public enum LinkScanner {
    public static func links(in document: MarkdownDocument) -> [MarkdownLink] {
        document.allInlines.compactMap { inline in
            guard inline.kind == .link || inline.kind == .autolink, let destination = inline.destination,
                  let destinationRange = inline.destinationRange else { return nil }
            return MarkdownLink(range: inline.range, labelRange: inline.contentRange, label: document.text[inline.contentRange],
                                destination: destination, destinationRange: destinationRange)
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    public static func links(in string: String, parser: MarkdownParser = .standard) -> [MarkdownLink] {
        links(in: parser.parse(string))
    }

    /// The link whose range contains `offset`.
    public static func link(at offset: Int, in document: MarkdownDocument) -> MarkdownLink? {
        links(in: document).first { $0.range.contains(offset) }
    }

    /// Replaces each link for which `transform` returns a string.
    public static func rewrite(_ string: String, parser: MarkdownParser = .standard,
                               _ transform: (MarkdownLink) -> String?) -> String {
        let document = parser.parse(string)
        let edits = links(in: document).compactMap { link in
            transform(link).map { TextEdit(range: link.range, replacement: $0) }
        }
        guard !edits.isEmpty else { return string }
        return EditResult(edits: edits, selection: 0..<0).apply(to: string)
    }
}

/// Markdown → plain text, for snippets, popovers and titles.
public enum PlainText {
    /// A whole body as plain text: block markers (`#`, `- [ ]`, `>`, fences) and inline syntax
    /// removed, one line per block, blank lines and dividers dropped. Used for search indexing.
    public static func document(_ markdown: String, parser: MarkdownParser = .standard) -> String {
        let document = parser.parse(markdown)
        return document.blocks.compactMap { block -> String? in
            let leaf = block.leaf
            switch leaf.kind {
            case .blank, .thematicBreak: return nil
            case .codeBlock: return document.text[leaf.contentRange]
            default:
                let text = strip(document.text[leaf.contentRange], parser: parser)
                return text.isEmpty ? nil : text
            }
        }.joined(separator: "\n")
    }

    /// Strips inline syntax characters from a fragment (block markers are left alone).
    public static func strip(_ markdown: String, parser: MarkdownParser = .standard) -> String {
        let text = MarkdownText(markdown)
        let inlines = parser.parseInlines(in: text, range: 0..<text.length)
        let syntax = inlines.flatMap(\.flattened).flatMap(\.syntax).sorted { $0.lowerBound < $1.lowerBound }
        var units: [UInt16] = []
        var cursor = 0
        for range in syntax where range.lowerBound >= cursor {
            units += text.units[cursor..<range.lowerBound]
            cursor = range.upperBound
        }
        units += text.units[min(cursor, text.length)...]
        return String(decoding: units, as: UTF16.self)
    }
}
