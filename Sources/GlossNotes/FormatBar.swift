import GlossMarkdown

/// One button of the floating format bar (and its menu and shortcut).
public struct FormatBarItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    /// Key equivalent with ⌘ (and ⇧ when `shift`).
    public let key: Character
    public let shift: Bool
    public let command: any MarkdownEditCommand

    public var shortcutLabel: String { (shift ? "⇧⌘" : "⌘") + String(key).uppercased() }
}

/// The format bar's contents, in order: bold, italic, heading, list, quote, code, link.
///
/// Shortcuts follow Apple Notes' Format menu: ⇧⌘H heading,
/// ⇧⌘7 bulleted list, ⌘' block quote, ⇧⌘M monospaced. ⌘K belongs to "link to passage" (the
/// plan's Edit-menu command), so the plain web link takes ⇧⌘K.
public enum FormatBar {
    public static let items: [FormatBarItem] = [
        FormatBarItem(id: "bold", title: "bold", symbol: "bold", key: "b", shift: false, command: ToggleInline.bold),
        FormatBarItem(id: "italic", title: "italic", symbol: "italic", key: "i", shift: false, command: ToggleInline.italic),
        FormatBarItem(id: "list", title: "list", symbol: "list.bullet", key: "7", shift: true, command: ToggleList(.bullet)),
        FormatBarItem(id: "quote", title: "quote", symbol: "text.quote", key: "'", shift: false, command: ToggleQuote()),
        FormatBarItem(id: "code", title: "code", symbol: "chevron.left.forwardslash.chevron.right", key: "m", shift: true, command: ToggleCode()),
        FormatBarItem(id: "link", title: "link", symbol: "link", key: "k", shift: true, command: InsertLinkTemplate()),
    ]

    /// Shortcuts the format bar must never take: system-wide ones, the standard app and Edit
    /// menu ones, and the ones gloss assigns elsewhere (⌘K link to passage, ⌘[ ⌘] history,
    /// ⇧⌘O open quickly, ⇧⌘A file › import — Apple Books' "add to library").
    public static let reservedShortcuts: Set<String> = [
        "⇧⌘Q", "⌘Q", "⌘W", "⌘N", "⌘O", "⌘S", "⌘P", "⌘H", "⌘M", "⌘,", "⌘Z", "⇧⌘Z", "⌘X", "⌘C", "⌘V", "⌘A",
        "⌘F", "⌘G", "⇧⌘G", "⌘T", "⌘K", "⌘[", "⌘]", "⇧⌘O", "⇧⌘N", "⇧⌘A",
    ]

    /// Which buttons show as "on" for a selection.
    public static func activeItems(in document: MarkdownDocument, selection: Range<Int>) -> Set<String> {
        Set(items.filter { $0.command.isActive(document, selection: selection) }.map(\.id))
    }

    /// The bar shows over non-empty selections that are not inside a subpage row.
    public static func shouldShow(selection: Range<Int>, subpageRows: [SubpageRow]) -> Bool {
        !selection.isEmpty && !subpageRows.contains { $0.lineRange.lowerBound <= selection.lowerBound && selection.upperBound <= $0.lineRange.upperBound }
    }
}
