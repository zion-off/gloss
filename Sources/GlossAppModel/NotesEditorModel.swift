import Foundation
import Observation
import GlossCore
import GlossMarkdown
import GlossNotes

/// Where drawn tables' column widths are kept: the library's settings, one entry per page,
/// mapping each resized table's ordinal on the page to its widths. View state only: never in the
/// markdown, so exports, the CLI, search and `gloss link` never see it.
public enum NotesTableSettings {
    public static func columnWidths(for page: PageID) -> SettingKey<[String: TableColumnWidths]> {
        SettingKey("notes.tableColumns.\(page.stringValue)", default: [:])
    }
}

/// The notes editor's behaviour, without TextKit. The text view stays the source of truth while
/// the user types (so input methods and undo stay native): it reports changes here, and applies
/// the edits this model returns through its own change APIs.
@MainActor @Observable public final class NotesEditorModel {
    /// A slash-menu row.
    public struct SlashItem: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var subtitle: String
        public var symbol: String
    }

    /// The open slash menu.
    public struct SlashMenu: Equatable, Sendable {
        public var trigger: SlashTrigger
        public var items: [SlashItem]
        public var selectedIndex: Int
    }

    /// A table the editor draws as a grid, and the column widths it uses.
    public struct GridTable: Hashable, Sendable {
        /// Its position among the page's tables.
        public var ordinal: Int
        public var table: MarkdownTable
        /// Each column's share of the table's width, from stored widths that fit it; nil lays
        /// the columns out automatically.
        public var columnFractions: [Double]?
    }

    public enum SaveState: Equatable, Sendable {
        case saved
        case pending
        case failed(String)
    }

    /// Keys whose meaning depends on the editor's state (the text view maps its command selectors
    /// onto these: `insertNewline:`, `insertTab:`, `insertBacktab:`, `cancelOperation:`,
    /// `moveUp:`, `moveDown:`).
    public enum KeyCommand: Sendable {
        case newline, tab, backtab, cancel, up, down
    }

    /// What the text view should do with a key command.
    public enum KeyOutcome: Equatable, Sendable {
        /// Let the text view do its default.
        case passThrough
        /// The model took it (the slash menu moved or closed); do nothing else.
        case handled
        /// Apply this edit through the text view's change APIs.
        case apply(EditResult)
        /// Run the selected slash command (`confirmSlashMenu()`) and apply its result.
        case confirmSlashMenu
    }

    public enum EditorError: Error, Equatable, Sendable {
        /// The open page's text couldn't be saved (the reason), so it wasn't replaced.
        case unsavedChanges(String)
    }

    public private(set) var page: Page?
    public private(set) var breadcrumbs: [Page] = []
    public private(set) var text = ""
    public private(set) var selection: Range<Int> = 0..<0
    /// The text in the notes dialect (`MarkdownParser.notes`: standard plus pipe tables).
    public private(set) var document = MarkdownParser.notes.parse("")
    /// Styling for the whole text, with the syntax under the selection revealed.
    public private(set) var spans: [StyleSpan] = []
    public private(set) var subpageRows: [SubpageRow] = []
    /// The page's tables, in order: a table's ordinal is its index here.
    public private(set) var tables: [MarkdownTable] = []
    /// The tables drawn as grids: all of them except one the selection touches, which shows its
    /// markdown for editing (no convert step: leaving it draws it). A caret counts only while the
    /// editor has focus; a selection (a find match, say) always does, or it would sit hidden.
    public private(set) var gridTables: [GridTable] = []
    /// Children with no block line, listed after the text ("more pages in here").
    public private(set) var unplacedChildren: [Page] = []
    public private(set) var activeFormats: Set<String> = []
    public private(set) var slashMenu: SlashMenu?
    public private(set) var saveState: SaveState = .saved

    /// Called after a save that added or removed `gloss://` links (markers need redrawing).
    public var linksDidChange: @MainActor () async -> Void = {}

    private let services: GlossServices
    private let slashCommands: SlashCommandRegistry
    private let saveDelay: Duration
    private var styler = NotesStyler()
    private var linkStatuses: [GlossLink: LinkStatus] = [:]
    private var children: [Page] = []
    private var savedLinks: Set<GlossLink> = []
    /// The debounce timer for the next save.
    private var saveTask: Task<Void, Never>?
    /// Writes run one after another, each writing the text current when it runs, so the newest
    /// text always lands last.
    private var writeChain: Task<Void, Never>?
    private var dismissedSlashAt: Int?
    private var generation = 0
    /// Whether the text view has keyboard focus: without it there is no caret to edit a table with.
    private var isFocused = false
    /// The open page's resized tables, by ordinal (`NotesTableSettings`).
    private var columnWidths: [Int: TableColumnWidths] = [:]
    /// Width writes run one after another, each with the widths of its moment.
    private var columnWidthsWrite: Task<Void, Never>?

    public init(services: GlossServices, slashCommands: SlashCommandRegistry? = nil, saveDelay: Duration = .milliseconds(500)) {
        self.services = services
        self.slashCommands = slashCommands ?? SlashCommandRegistry.standard(pages: services.pages)
        self.saveDelay = saveDelay
    }

    /// Text the store doesn't have yet: a save is pending, or the last one failed.
    public var isDirty: Bool { saveState != .saved }

    // MARK: Loading

    /// Shows a page. The open page's unsaved text is saved first; if that fails the open page
    /// stays and this throws `unsavedChanges`, so the text is never dropped silently. Pass
    /// `discardingUnsaved` once the user chose to let it go.
    public func load(_ page: Page, discardingUnsaved: Bool = false) async throws {
        // The page already shown keeps the editor's text: the passed value may be older than
        // what was typed (a "keep editing" after a failed save, a re-selection). External
        // changes arrive through `pageChangedExternally` instead.
        if page.id == self.page?.id, !discardingUnsaved { return }
        await flushSave()
        if case .failed(let reason) = saveState, !discardingUnsaved {
            throw EditorError.unsavedChanges(reason)
        }
        saveTask?.cancel()
        saveTask = nil
        self.page = page
        text = page.body
        selection = 0..<0
        columnWidths = [:]  // the old page's: never on this one's tables, even while these load
        // `document` must follow `text` before the first suspension below: the view installs the
        // new text while this call awaits, and AppKit's selection callback reads `document`.
        reparse()
        slashMenu = nil
        dismissedSlashAt = nil
        saveState = .saved
        savedLinks = NotesStyler.glossLinks(in: MarkdownParser.standard.parse(page.body))
        breadcrumbs = (try? await services.pages.breadcrumbs(to: page.id)) ?? [page]
        await loadColumnWidths(for: page.id)
        await refreshContext()
    }

    /// Renames a page from the title field. An empty title shows as "untitled" everywhere. The
    /// body in the editor is untouched (it may hold unsaved text); only the title is refreshed.
    public func rename(_ id: PageID, to title: String) async {
        guard let renamed = try? await services.pages.rename(id, to: title) else { return }
        guard id == page?.id else { return }
        page?.title = renamed.title
        if !breadcrumbs.isEmpty { breadcrumbs[breadcrumbs.count - 1].title = renamed.title }
    }

    /// Picks up a change made elsewhere (the CLI, another window). Unsaved local edits win: they
    /// are saved over it, the way a second save from another app would be. After a failed save
    /// the change is the cue to try again (the page may be back from the trash).
    public func pageChangedExternally() async {
        guard let id = page?.id else { return }
        if isDirty {
            if case .failed = saveState { await flushSave() }
            return
        }
        let fresh: Page?
        do { fresh = try await services.pages.page(id) } catch { return }  // a failed read proves nothing
        guard let fresh, fresh.trash == nil else { unload(); return }
        if fresh.body != text {
            text = fresh.body
            selection = clamp(selection)
            reparse()  // same reason as in `load`: the view hears the text before the next await ends
        }
        page = fresh
        // The title may have changed too (a rename, a details edit): keep the crumbs honest.
        breadcrumbs = (try? await services.pages.breadcrumbs(to: id)) ?? breadcrumbs
        savedLinks = NotesStyler.glossLinks(in: MarkdownParser.standard.parse(fresh.body))
        await refreshContext()
    }

    /// Shows nothing (the page was trashed or purged elsewhere, with nothing unsaved).
    private func unload() {
        saveTask?.cancel()
        saveTask = nil
        page = nil
        breadcrumbs = []
        text = ""
        selection = 0..<0
        slashMenu = nil
        dismissedSlashAt = nil
        children = []
        savedLinks = []
        columnWidths = [:]
        reparse()
    }

    // MARK: Input from the text view

    public func textDidChange(_ newText: String, selection newSelection: Range<Int>) {
        guard newText != text else { selectionDidChange(newSelection); return }
        text = newText
        selection = clamp(newSelection)
        reparse()
        updateSlashMenu()
        scheduleSave()
    }

    public func selectionDidChange(_ newSelection: Range<Int>) {
        selection = clamp(newSelection)
        refreshPresentation()
        updateSlashMenu()
    }

    /// The text view gained or lost keyboard focus.
    public func focusDidChange(_ focused: Bool) {
        guard focused != isFocused else { return }
        isFocused = focused
        refreshPresentation()
    }

    // MARK: Commands (each returns an edit for the text view to apply)

    public func run(_ command: any MarkdownEditCommand) -> EditResult? {
        command.edit(document, selection: selection)
    }

    /// Decides a key command: the open slash menu takes Return, Tab, Escape and the arrows;
    /// otherwise Return continues lists and quotes and Tab indents list items.
    public func keyCommand(_ command: KeyCommand) -> KeyOutcome {
        if let menu = slashMenu, !menu.items.isEmpty {
            switch command {
            case .up: moveSlashSelection(by: -1); return .handled
            case .down: moveSlashSelection(by: 1); return .handled
            case .newline, .tab: return .confirmSlashMenu
            case .cancel: dismissSlashMenu(); return .handled
            case .backtab: return .handled
            }
        }
        let result: EditResult?
        switch command {
        case .newline: result = returnKey()
        case .tab: result = tabKey(shift: false)
        case .backtab: result = tabKey(shift: true)
        case .cancel, .up, .down: result = nil
        }
        return result.map(KeyOutcome.apply) ?? .passThrough
    }

    /// Return: add or end a table row, continue or end a list or quote; nil means "insert a plain
    /// newline".
    public func returnKey() -> EditResult? {
        TableEditing.newline(in: document, selection: selection) ?? ListContinuation.newline(in: document, selection: selection)
    }

    /// Tab / Shift-Tab: indent or outdent list items; nil means "do the default".
    public func tabKey(shift: Bool) -> EditResult? {
        shift ? ListIndentation.outdent(in: document, selection: selection)
              : ListIndentation.indent(in: document, selection: selection)
    }

    /// A click on a task box.
    public func toggleTask(at offset: Int) -> EditResult? {
        TaskToggle.toggle(in: document, at: offset)
    }

    /// Whether a click lands on its line's task box. `offset` is an insertion index (what
    /// `characterIndexForInsertion(at:)` returns for a click), so it counts from just before `[`
    /// to just after `]`: a click on the right half of `]` gives the index after it.
    public func isTaskBox(at offset: Int) -> Bool {
        guard let box = TaskToggle.boxRange(in: document, at: offset) else { return false }
        return (box.lowerBound...box.upperBound).contains(offset)
    }

    // MARK: Links

    /// The gloss link under an offset (for clicks).
    public func glossLink(at offset: Int) -> GlossLink? {
        LinkScanner.link(at: offset, in: document).flatMap { GlossLink(string: $0.destination) }
    }

    /// The destination of any link under an offset (web links open in the browser).
    public func linkDestination(at offset: Int) -> String? {
        LinkScanner.link(at: offset, in: document)?.destination
    }

    /// What the hover popover shows for a passage link.
    public func preview(at offset: Int) async -> PassagePreview? {
        guard case .passage(let id)? = glossLink(at: offset) else { return nil }
        return try? await services.links.preview(of: id)
    }

    /// The subpage row under an offset (a click opens the page).
    public func subpageRow(at offset: Int) -> SubpageRow? {
        subpageRows.first { $0.lineRange.contains(offset) || $0.lineRange.upperBound == offset }
    }

    // MARK: Tables

    /// The drawn table covering an offset (the pointer's index over a grid).
    public func gridTable(at offset: Int) -> GridTable? {
        gridTables.first { $0.table.range.lowerBound <= offset && offset <= $0.table.range.upperBound }
    }

    /// Adds an empty row to the page's `ordinal`th table (a "+" handle, the grid's menu).
    public func addRow(toTable ordinal: Int) -> EditResult? {
        tables.indices.contains(ordinal) ? TableEditing.addRow(to: tables[ordinal], selection: selection) : nil
    }

    /// Adds an empty column to the page's `ordinal`th table.
    public func addColumn(toTable ordinal: Int) -> EditResult? {
        tables.indices.contains(ordinal) ? TableEditing.addColumn(to: tables[ordinal], selection: selection) : nil
    }

    /// Where a click on a drawn cell puts the caret: the end of the cell's text (`row` counts the
    /// grid's rows, header first). The table then shows its markdown with the caret in that cell.
    public func caret(inTable ordinal: Int, row: Int, column: Int) -> Int? {
        guard tables.indices.contains(ordinal) else { return nil }
        let rows = tables[ordinal].gridRows
        guard rows.indices.contains(row), rows[row].cells.indices.contains(column) else { return nil }
        return rows[row].cells[column].contentRange.upperBound
    }

    /// Columns resized by dragging a divider: each column's share of the table's width. Kept in
    /// memory (the grid redraws with it) until `saveColumnWidths()`; the text never changes.
    public func resizeColumns(ofTable ordinal: Int, to fractions: [Double]) {
        guard tables.indices.contains(ordinal), fractions.count == tables[ordinal].columnCount else { return }
        columnWidths[ordinal] = TableColumnWidths(fractions: fractions)
        refreshPresentation()
    }

    /// Back to automatic widths (a double-click on a divider), stored at once.
    public func resetColumnWidths(ofTable ordinal: Int) {
        guard columnWidths.removeValue(forKey: ordinal) != nil else { return }
        refreshPresentation()
        saveColumnWidths()
    }

    /// Stores the open page's column widths (when a divider drag ends).
    public func saveColumnWidths() {
        guard let page else { return }
        let key = NotesTableSettings.columnWidths(for: page.id)
        let value = Dictionary(uniqueKeysWithValues: columnWidths.map { (String($0.key), $0.value) })
        let settings = services.settings
        let previous = columnWidthsWrite
        columnWidthsWrite = Task {
            await previous?.value
            try? await settings.set(value, for: key)  // view state: a failed write only loses a width
        }
    }

    /// Waits until every width write so far is stored.
    public func flushColumnWidths() async {
        await columnWidthsWrite?.value
    }

    /// Reads a page's stored widths and drops entries for tables it no longer has (by ordinal:
    /// adding or removing a table above a resized one shifts its widths to another table).
    private func loadColumnWidths(for id: PageID) async {
        let stored = (try? await services.settings.value(NotesTableSettings.columnWidths(for: id))) ?? [:]
        guard page?.id == id else { return }
        let byOrdinal = Dictionary(stored.compactMap { key, value in Int(key).map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
        columnWidths = TableWidths.pruned(byOrdinal, tableCount: tables.count)
        refreshPresentation()
        if columnWidths.count != stored.count { saveColumnWidths() }
    }

    /// A paste of plain text: one holding a table goes in on lines of its own with the caret
    /// after it, so the grid draws at once. Nil pastes as usual.
    public func paste(_ string: String) -> EditResult? {
        TablePaste.edit(pasting: string, in: document, selection: selection)
    }

    // MARK: Slash menu

    public func moveSlashSelection(by delta: Int) {
        guard var menu = slashMenu, !menu.items.isEmpty else { return }
        menu.selectedIndex = (menu.selectedIndex + delta + menu.items.count) % menu.items.count
        slashMenu = menu
    }

    public func dismissSlashMenu() {
        dismissedSlashAt = slashMenu?.trigger.range.lowerBound
        slashMenu = nil
    }

    /// Runs the selected (or given) command. The result's edit replaces the trigger; `openPage`
    /// is set for `/page`.
    public func confirmSlashMenu(itemID: String? = nil) async throws -> SlashCommandResult? {
        guard let menu = slashMenu, let page else { return nil }
        let id = itemID ?? (menu.items.indices.contains(menu.selectedIndex) ? menu.items[menu.selectedIndex].id : nil)
        guard let command = slashCommands.commands.first(where: { $0.id == id }) else { return nil }
        slashMenu = nil
        let result = try await slashCommands.run(command, trigger: menu.trigger, in: document, page: page.id, parser: .notes)
        if result.openPage != nil { await refreshContext() }
        return result
    }

    // MARK: Saving

    /// Writes pending edits now and waits until they (and any earlier writes) are stored.
    public func flushSave() async {
        saveTask?.cancel()
        saveTask = nil
        await save()
    }

    private func scheduleSave() {
        guard page != nil else { return }
        saveState = .pending
        generation += 1
        let token = generation
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, token == self.generation else { return }
            await self.save()
        }
    }

    private func save() async {
        let previous = writeChain
        let write = Task { [weak self] in
            await previous?.value
            await self?.writeCurrentText()
        }
        writeChain = write
        await write.value
    }

    private func writeCurrentText() async {
        // `.failed` is dirty too: a retry (flush, window close) must write, not skip.
        guard let page, saveState != .saved else { return }
        let body = text
        do {
            let saved = try await services.pages.updateBody(page.id, to: body)
            guard self.page?.id == saved.id else { return }
            self.page = saved
            if text == body { saveState = .saved }
            let links = NotesStyler.glossLinks(in: MarkdownParser.standard.parse(body))
            if links != savedLinks {
                savedLinks = links
                await refreshLinkStatuses()
                await linksDidChange()
            }
        } catch {
            saveState = .failed((error as? GlossError)?.description ?? "couldn't save this page")
        }
    }

    // MARK: Internals

    private var baseSpans: [StyleSpan] = []

    private func refreshContext() async {
        guard let page else { return }
        children = (try? await services.pages.children(of: page.id)) ?? []
        await refreshLinkStatuses()
    }

    private func refreshLinkStatuses() async {
        var statuses: [GlossLink: LinkStatus] = [:]
        for link in NotesStyler.glossLinks(in: MarkdownParser.standard.parse(text)) {
            do {
                switch try await services.links.resolve(link) {
                case .inTrash: statuses[link] = .inTrash
                case .missing: statuses[link] = .missing
                default: statuses[link] = .live
                }
            } catch {
                // A failed lookup proves nothing: keep what was known, else don't call it broken.
                statuses[link] = linkStatuses[link] ?? .live
            }
        }
        linkStatuses = statuses
        styler = NotesStyler(statuses: statuses)
        reparse()
    }

    private func reparse() {
        document = MarkdownParser.notes.parse(text)
        tables = MarkdownTable.all(in: document)
        subpageRows = SubpageRows.rows(in: document, children: children)
        let placed = Set(subpageRows.map(\.pageID))
        unplacedChildren = children.filter { !placed.contains($0.id) }
        baseSpans = styler.spans(for: document, subpageRows: subpageRows)
        refreshPresentation()
    }

    /// What depends on the selection and focus: which tables draw as grids, the revealed syntax,
    /// the format bar's state.
    private func refreshPresentation() {
        gridTables = tables.enumerated().compactMap { ordinal, table in
            // Touching, as for syntax reveal: a caret at either end of the table is in it.
            let touches = selection.lowerBound <= table.range.upperBound && selection.upperBound >= table.range.lowerBound
            let editing = touches && (isFocused || !selection.isEmpty)
            return editing ? nil : GridTable(ordinal: ordinal, table: table,
                                             columnFractions: TableWidths.applicable(columnWidths[ordinal], columnCount: table.columnCount))
        }
        let grids = gridTables.map { StyleSpan(range: $0.table.range, role: NotesRole.tableGrid) }
        spans = SyntaxReveal.apply(baseSpans + grids, selection: selection, concealed: subpageRows.map(\.lineRange))
        activeFormats = FormatBar.activeItems(in: document, selection: selection)
    }

    private func updateSlashMenu() {
        guard selection.isEmpty, let trigger = SlashTrigger.detect(in: document, caret: selection.lowerBound),
              trigger.range.lowerBound != dismissedSlashAt else {
            slashMenu = nil
            if let dismissed = dismissedSlashAt, dismissed >= text.utf16.count || MarkdownText(text).unit(at: dismissed) != 0x2F {
                dismissedSlashAt = nil
            }
            return
        }
        let items = slashCommands.matches(trigger.query).map {
            SlashItem(id: $0.id, title: $0.title, subtitle: $0.subtitle, symbol: $0.symbol)
        }
        guard !items.isEmpty else { slashMenu = nil; return }
        let keep = slashMenu.map { $0.trigger.range.lowerBound == trigger.range.lowerBound } ?? false
        slashMenu = SlashMenu(trigger: trigger, items: items, selectedIndex: keep ? min(slashMenu!.selectedIndex, items.count - 1) : 0)
    }

    private func clamp(_ range: Range<Int>) -> Range<Int> {
        let length = text.utf16.count
        let lower = min(max(0, range.lowerBound), length)
        return lower..<min(max(lower, range.upperBound), length)
    }
}
