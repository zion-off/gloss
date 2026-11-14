import GlossMarkdown

/// What a run of notes text looks like, in semantic terms: the Mac editor maps font roles to
/// system fonts and colour roles to system colours (label, secondary label, link, accent), so
/// light/dark mode and Increase Contrast come for free. `nil` means "inherit".
public struct TextStyle: Hashable, Sendable {
    public enum FontRole: Hashable, Sendable {
        case body
        case heading(Int)
        case monospaced
    }

    public enum ColorRole: Hashable, Sendable {
        case text, secondary, tertiary, link, accent, warning
    }

    public enum Underline: Hashable, Sendable {
        /// `subtle`: a thin line in a muted colour, a link's.
        case single, dotted, subtle
    }

    /// Paragraph treatment for the lines a block covers. `row`: a subpage row's line, one fixed
    /// height that never wraps, whatever its hidden text. `table`: a drawn table's line, which
    /// never wraps either; the editor sets its height from the grid's layout.
    public enum Block: Hashable, Sendable {
        case quote, code, row, table
    }

    public var font: FontRole?
    public var bold: Bool?
    public var italic: Bool?
    public var color: ColorRole?
    public var strikethrough: Bool?
    public var underline: Underline?
    public var block: Block?
    /// Kept in the text but not drawn (a subpage line under its row).
    public var hidden: Bool?
    /// Kept in the text but shrunk to nothing: no glyph, no width (hidden markdown syntax).
    public var collapsed: Bool?

    public init(font: FontRole? = nil, bold: Bool? = nil, italic: Bool? = nil, color: ColorRole? = nil,
                strikethrough: Bool? = nil, underline: Underline? = nil, block: Block? = nil, hidden: Bool? = nil,
                collapsed: Bool? = nil) {
        self.font = font
        self.bold = bold
        self.italic = italic
        self.color = color
        self.strikethrough = strikethrough
        self.underline = underline
        self.block = block
        self.hidden = hidden
        self.collapsed = collapsed
    }

    /// This style with every property `other` sets taking its value.
    public func merging(_ other: TextStyle) -> TextStyle {
        TextStyle(font: other.font ?? font, bold: other.bold ?? bold, italic: other.italic ?? italic,
                  color: other.color ?? color, strikethrough: other.strikethrough ?? strikethrough,
                  underline: other.underline ?? underline, block: other.block ?? block, hidden: other.hidden ?? hidden,
                  collapsed: other.collapsed ?? collapsed)
    }
}

/// A stretch of text with one resolved style.
public struct StyledRun: Hashable, Sendable {
    public var range: Range<Int>
    public var style: TextStyle

    public init(range: Range<Int>, style: TextStyle) {
        self.range = range
        self.style = style
    }
}

/// Roles → styles, and how overlapping spans combine: each role sits on a layer, and higher
/// layers override lower ones (a dimmed `**` inside a heading keeps the heading font but takes
/// the syntax colour). Open: a new role only needs an entry here.
public struct NotesTheme: Sendable {
    public struct Entry: Sendable {
        public var style: TextStyle
        public var layer: Int

        public init(_ style: TextStyle, layer: Int) {
            self.style = style
            self.layer = layer
        }
    }

    public var entries: [StyleRole: Entry]

    public init(entries: [StyleRole: Entry]) {
        self.entries = entries
    }

    public static let standard: NotesTheme = {
        var entries: [StyleRole: Entry] = [
            .quote: Entry(TextStyle(color: .secondary, block: .quote), layer: 0),
            .codeBlock: Entry(TextStyle(font: .monospaced, block: .code), layer: 0),
            .tableSource: Entry(TextStyle(font: .monospaced), layer: 0),
            .tableHeader: Entry(TextStyle(bold: true), layer: 3),
            .tableSyntax: Entry(TextStyle(color: .tertiary), layer: 6),
            .code: Entry(TextStyle(font: .monospaced), layer: 2),
            .strong: Entry(TextStyle(bold: true), layer: 3),
            .emphasis: Entry(TextStyle(italic: true), layer: 3),
            .strikethrough: Entry(TextStyle(strikethrough: true), layer: 3),
            // Every live link looks the same, Notion's way: muted text over a faint underline.
            .link: Entry(TextStyle(color: .link, underline: .subtle), layer: 4),
            NotesRole.pageLink: Entry(TextStyle(color: .link, underline: .subtle), layer: 5),
            NotesRole.bookLink: Entry(TextStyle(color: .link, underline: .subtle), layer: 5),
            NotesRole.passageLink: Entry(TextStyle(color: .link, underline: .subtle), layer: 5),
            NotesRole.trashedLink: Entry(TextStyle(color: .secondary, strikethrough: true), layer: 5),
            NotesRole.brokenLink: Entry(TextStyle(color: .warning, underline: .dotted), layer: 5),
            .listMarker: Entry(TextStyle(color: .secondary), layer: 6),
            .taskBox: Entry(TextStyle(font: .monospaced, color: .secondary), layer: 6),
            .taskBoxChecked: Entry(TextStyle(font: .monospaced, color: .accent), layer: 6),
            .taskDone: Entry(TextStyle(color: .secondary, strikethrough: true), layer: 6),
            .thematicBreak: Entry(TextStyle(color: .tertiary), layer: 6),
            // Syntax and link destinations are in the text but not on the page; the cursor
            // touching their element brings them back, dimmed.
            .linkDestination: Entry(TextStyle(collapsed: true), layer: 7),
            .linkDestinationRevealed: Entry(TextStyle(color: .tertiary, underline: nil), layer: 7),
            .syntax: Entry(TextStyle(collapsed: true), layer: 8),
            .syntaxRevealed: Entry(TextStyle(color: .tertiary), layer: 8),
            NotesRole.subpageBlock: Entry(TextStyle(block: .row, hidden: true), layer: 9),
            NotesRole.tableGrid: Entry(TextStyle(block: .table, hidden: true), layer: 9),
        ]
        for level in 1...6 {
            entries[.heading(level)] = Entry(TextStyle(font: .heading(level), bold: true), layer: 1)
        }
        return NotesTheme(entries: entries)
    }()

    /// Flattens spans into runs that cover `0..<length` exactly, without gaps or overlaps, with
    /// equal neighbours merged. Spans with unknown roles or empty ranges are ignored.
    public func runs(for spans: [StyleSpan], length: Int) -> [StyledRun] {
        guard length > 0 else { return [] }
        struct Event { var position: Int; var opens: Bool; var index: Int }
        var events: [Event] = []
        for (index, span) in spans.enumerated() where entries[span.role] != nil {
            let lower = min(max(span.range.lowerBound, 0), length), upper = min(max(span.range.upperBound, 0), length)
            guard lower < upper else { continue }
            events.append(Event(position: lower, opens: true, index: index))
            events.append(Event(position: upper, opens: false, index: index))
        }
        events.sort { $0.position < $1.position }

        var runs: [StyledRun] = []
        var active: [Int] = []
        var position = 0
        var cursor = 0
        func emit(upTo end: Int) {
            guard end > position else { return }
            let style = active
                .sorted { (entries[spans[$0].role]!.layer, $0) < (entries[spans[$1].role]!.layer, $1) }
                .reduce(TextStyle()) { $0.merging(entries[spans[$1].role]!.style) }
            if let last = runs.last, last.style == style, last.range.upperBound == position {
                runs[runs.count - 1].range = last.range.lowerBound..<end
            } else {
                runs.append(StyledRun(range: position..<end, style: style))
            }
            position = end
        }
        while cursor < events.count {
            let at = events[cursor].position
            emit(upTo: at)
            while cursor < events.count, events[cursor].position == at {
                let event = events[cursor]
                if event.opens { active.append(event.index) } else { active.removeAll { $0 == event.index } }
                cursor += 1
            }
        }
        emit(upTo: length)
        return runs
    }
}

public enum StyledRunDiff {
    /// The ranges whose style differs between two run lists over text of the same length (a
    /// selection move that revealed other syntax). Lists of different lengths differ everywhere.
    public static func changedRanges(from old: [StyledRun], to new: [StyledRun]) -> [Range<Int>] {
        let oldLength = old.last?.range.upperBound ?? 0, newLength = new.last?.range.upperBound ?? 0
        guard oldLength == newLength else { return max(oldLength, newLength) > 0 ? [0..<max(oldLength, newLength)] : [] }
        var changed: [Range<Int>] = []
        var i = 0, j = 0, position = 0
        while i < old.count, j < new.count {
            let end = min(old[i].range.upperBound, new[j].range.upperBound)
            if old[i].style != new[j].style, end > position {
                if let last = changed.last, last.upperBound == position {
                    changed[changed.count - 1] = last.lowerBound..<end
                } else {
                    changed.append(position..<end)
                }
            }
            position = end
            if old[i].range.upperBound == end { i += 1 }
            if new[j].range.upperBound == end { j += 1 }
        }
        return changed
    }
}
