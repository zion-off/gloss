import GlossMarkdown

/// How the editor indents list items, Notion's way: the markdown's leading spaces are hidden and
/// each nesting level moves the line one marker column right; after the marker the text starts
/// at the next column, and lines the item wraps onto start there too. Sizes are in ems of the
/// body text, so they follow the text size. The editor only measures the marker.
public enum ListLayout {
    /// One list item's line.
    public struct Line: Hashable, Sendable {
        /// The whole line (a quoted item's includes its `> `).
        public var line: Range<Int>
        public var level: Int
        /// The marker as written, with the space after it (`- `, `1. `, `- [ ] `).
        public var marker: Range<Int>
        /// Inside a quote, whose own indent the list's adds to.
        public var quoted: Bool

        /// The line up to its text: indentation, any quote marker, the list marker.
        public var prefix: Range<Int> { line.lowerBound..<marker.upperBound }
    }

    /// What a prefix character shows as, so the line can't break inside the prefix: a long first
    /// word otherwise wraps to the next line whole and leaves the marker alone on its own. One
    /// UTF-16 unit for one, so offsets stay put; nil keeps the character. The narrow no-break
    /// space, because Core Text still breaks after a plain one (U+00A0) before an overlong word;
    /// the space inside a task box stays, the line can't break there anyway.
    public static func unbreakable(_ unit: UInt16, after previous: UInt16?) -> UInt16? {
        switch unit {
        case 0x20 where previous == 0x5B: nil  // `[ ]`
        case 0x20, 0x09: 0x202F  // space, tab: narrow no-break space
        case 0x2D: 0x2011  // hyphen-minus: non-breaking hyphen
        default: nil
        }
    }

    /// Where a list line's text goes, in points.
    public struct Indents: Hashable, Sendable {
        /// The marker's start.
        public var firstLine: Double
        /// The text's start, on the first line and every line it wraps onto.
        public var head: Double
        /// Extra space after the marker that brings the text out to `head`.
        public var gap: Double
    }

    /// The marker column, in ems: a bullet or a one-digit number and its space fit in it.
    public static let column = 1.5

    /// Every list item's line, in document order.
    public static func lines(in document: MarkdownDocument) -> [Line] {
        var result: [Line] = []
        func visit(_ block: Block, line: Range<Int>, quoted: Bool) {
            if block.kind == .listItem, let marker = block.syntax.first {
                result.append(Line(line: line, level: block.attributes.indent ?? 0, marker: marker, quoted: quoted))
            }
            for child in block.children { visit(child, line: line, quoted: quoted || block.kind == .quote) }
        }
        for block in document.blocks { visit(block, line: block.range, quoted: false) }
        return result
    }

    /// The indents for a line at `level` whose marker measures `markerWidth`, in body text of
    /// `bodySize`, starting from `base` (a quote's indent). A marker wider than the column
    /// pushes its own text out rather than overlapping it.
    public static func indents(level: Int, markerWidth: Double, bodySize: Double, base: Double = 0) -> Indents {
        let column = Self.column * bodySize
        let first = base + Double(level) * column
        let gap = max(0, column - markerWidth)
        return Indents(firstLine: first, head: first + markerWidth + gap, gap: gap)
    }
}
