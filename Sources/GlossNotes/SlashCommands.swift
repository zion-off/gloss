import GlossCore
import GlossMarkdown

/// `/query` typed at the caret.
public struct SlashTrigger: Hashable, Sendable {
    /// The `/` and the query after it.
    public var range: Range<Int>
    public var query: String

    public static let maxQueryLength = 24

    /// Finds a trigger ending at `caret`: a `/` at the start of a line or after whitespace,
    /// followed by letters, digits or `-`. Never inside code or a table.
    public static func detect(in document: MarkdownDocument, caret: Int) -> SlashTrigger? {
        let text = document.text
        // A caret from a newer text than this parse (the view reports before the model has
        // caught up) means there is nothing to find yet, not a crash.
        guard caret >= 0, caret <= text.units.count else { return nil }
        var start = caret
        while start > 0 {
            let unit = text.units[start - 1]
            guard let scalar = Unicode.Scalar(unit), scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "-" else { break }
            start -= 1
        }
        guard start > 0, text.units[start - 1] == 0x2F else { return nil }
        let slash = start - 1
        if slash > 0 {
            let before = text.units[slash - 1]
            guard before == 0x20 || before == 0x09 || before == 0x0A else { return nil }
        }
        guard caret - start <= maxQueryLength else { return nil }
        // Not in code, and not in a table's source, where a block command would break the table.
        if document.blocks.contains(where: { ($0.kind == .codeBlock || $0.kind == .table) && $0.range.contains(slash) }) { return nil }
        if document.allInlines.contains(where: { $0.kind == .code && $0.range.contains(slash) }) { return nil }
        return SlashTrigger(range: slash..<caret, query: text[start..<caret])
    }
}

/// What running a slash command asks the editor to do.
public struct SlashCommandResult: Hashable, Sendable {
    /// One replacement against the text *with* the trigger, so it applies as one undo step.
    public var edit: TextEdit
    public var selection: Range<Int>
    /// A page to open afterwards (the new subpage for `/page`).
    public var openPage: PageID?
}

/// A slash-menu entry. Register new ones in the `SlashCommandRegistry`.
public protocol SlashCommand: Sendable {
    var id: String { get }
    var title: String { get }
    var subtitle: String { get }
    /// An SF Symbol name for the menu row.
    var symbol: String { get }
    var keywords: [String] { get }
    /// Runs with the trigger already removed: `document` is the text without it and `caret`
    /// is where it was.
    func run(on document: MarkdownDocument, caret: Int, page: PageID) async throws -> (result: EditResult, openPage: PageID?)
}

/// The registered commands, ranked for a query.
public struct SlashCommandRegistry: Sendable {
    public var commands: [any SlashCommand]

    public init(_ commands: [any SlashCommand]) { self.commands = commands }

    /// gloss's built-in commands. `/page` needs the page service to create the subpage.
    public static func standard(pages: PageService) -> SlashCommandRegistry {
        SlashCommandRegistry([
            NewPageCommand(pages: pages),
            FormatSlashCommand(id: "h1", title: "heading 1", subtitle: "a big section title", symbol: "textformat.size.larger",
                               keywords: ["title", "h1", "#"], command: ToggleHeading(level: 1)),
            FormatSlashCommand(id: "h2", title: "heading 2", subtitle: "a medium heading", symbol: "textformat.size",
                               keywords: ["subtitle", "h2", "##"], command: ToggleHeading(level: 2)),
            FormatSlashCommand(id: "h3", title: "heading 3", subtitle: "a small heading", symbol: "textformat.size.smaller",
                               keywords: ["h3", "###"], command: ToggleHeading(level: 3)),
            FormatSlashCommand(id: "todo", title: "to-do", subtitle: "a checkbox to tick off", symbol: "checklist",
                               keywords: ["task", "check", "checkbox"], command: ToggleList(.task)),
            FormatSlashCommand(id: "bullet", title: "bulleted list", subtitle: "a simple list", symbol: "list.bullet",
                               keywords: ["list", "ul", "-"], command: ToggleList(.bullet)),
            FormatSlashCommand(id: "numbered", title: "numbered list", subtitle: "one, two, three", symbol: "list.number",
                               keywords: ["ordered", "ol", "1."], command: ToggleList(.ordered)),
            FormatSlashCommand(id: "quote", title: "quote", subtitle: "a block quote", symbol: "text.quote",
                               keywords: ["blockquote", ">"], command: ToggleQuote()),
            FormatSlashCommand(id: "code", title: "code", subtitle: "a block of monospaced text", symbol: "chevron.left.forwardslash.chevron.right",
                               keywords: ["snippet", "```"], command: ToggleCodeBlock()),
            FormatSlashCommand(id: "table", title: "table", subtitle: "rows and columns", symbol: "tablecells",
                               keywords: ["grid", "columns", "rows", "|"], command: InsertTable()),
            FormatSlashCommand(id: "divider", title: "divider", subtitle: "a line across", symbol: "minus",
                               keywords: ["rule", "hr", "line", "---"], command: InsertDivider()),
        ])
    }

    /// Commands matching `query`, best first; registry order for an empty query.
    public func matches(_ query: String) -> [any SlashCommand] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return commands }
        let scored = commands.enumerated().compactMap { index, command -> (Double, Int, any SlashCommand)? in
            let score = Self.score(command, needle)
            return score > 0 ? (score, index, command) : nil
        }
        return scored.sorted { ($0.0, -$0.1) > ($1.0, -$1.1) }.map(\.2)
    }

    static func score(_ command: any SlashCommand, _ needle: String) -> Double {
        let title = command.title.lowercased()
        if command.id == needle || title == needle { return 10 }
        if title.hasPrefix(needle) || command.id.hasPrefix(needle) { return 6 }
        let words = title.split(whereSeparator: { $0 == " " || $0 == "-" })
        if words.contains(where: { $0.hasPrefix(needle) }) { return 5 }
        // Initials ("bl" → "bulleted list").
        if words.count > 1, String(words.compactMap(\.first)).hasPrefix(needle) { return 4.5 }
        if command.keywords.contains(where: { $0.lowercased().hasPrefix(needle) }) { return 4 }
        if title.contains(needle) { return 2 }
        // Subsequence ("bl" → "bulleted list").
        var remaining = Substring(needle)
        for char in title where char == remaining.first { remaining = remaining.dropFirst() }
        return remaining.isEmpty ? 1 : 0
    }

    /// Runs `command` for `trigger` and folds trigger removal and the command into one edit.
    public func run(_ command: any SlashCommand, trigger: SlashTrigger, in document: MarkdownDocument, page: PageID,
                    parser: MarkdownParser = .standard) async throws -> SlashCommandResult {
        let original = document.text.string
        let removal = EditResult(edits: [.delete(trigger.range)], selection: trigger.range.lowerBound..<trigger.range.lowerBound)
        let withoutTrigger = removal.apply(to: original)
        let (result, openPage) = try await command.run(on: parser.parse(withoutTrigger), caret: trigger.range.lowerBound, page: page)
        let final = result.apply(to: withoutTrigger)
        let edit = TextDiff.minimalEdit(from: original, to: final) ?? TextEdit(range: trigger.range, replacement: "")
        return SlashCommandResult(edit: edit, selection: result.selection, openPage: openPage)
    }
}

/// A slash command that runs a markdown formatting command at the caret.
public struct FormatSlashCommand: SlashCommand {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbol: String
    public let keywords: [String]
    let command: any MarkdownEditCommand

    public init(id: String, title: String, subtitle: String, symbol: String, keywords: [String], command: any MarkdownEditCommand) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.keywords = keywords
        self.command = command
    }

    public func run(on document: MarkdownDocument, caret: Int, page: PageID) async throws -> (result: EditResult, openPage: PageID?) {
        let result = command.edit(document, selection: caret..<caret) ?? EditResult(edits: [], selection: caret..<caret)
        return (result, nil)
    }
}

/// `/page`: creates a subpage and places its block line at the caret.
public struct NewPageCommand: SlashCommand {
    let pages: PageService
    public init(pages: PageService) { self.pages = pages }

    public var id: String { "page" }
    public var title: String { "page" }
    public var subtitle: String { "a new page inside this one" }
    public var symbol: String { "doc.text" }
    public var keywords: [String] { ["subpage", "new", "child"] }

    public func run(on document: MarkdownDocument, caret: Int, page: PageID) async throws -> (result: EditResult, openPage: PageID?) {
        let child = try await pages.createSubpage(under: page)
        let line = PageBlockLines.line(for: child.id, title: child.title)
        let text = document.text
        let lineRange = text.lines[text.lineIndex(containing: caret)]
        let edit: TextEdit
        let caretAfter: Int
        if text.isBlank(lineRange) {
            edit = TextEdit(range: lineRange, replacement: line)
            caretAfter = lineRange.lowerBound + line.utf16.count
        } else {
            edit = .insert("\n" + line, at: lineRange.upperBound)
            caretAfter = lineRange.upperBound + 1 + line.utf16.count
        }
        return (EditResult(edits: [edit], selection: caretAfter..<caretAfter), child.id)
    }
}
