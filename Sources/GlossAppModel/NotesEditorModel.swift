import Foundation
import Observation
import GlossCore
import GlossMarkdown
import GlossNotes

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

    public enum SaveState: Equatable, Sendable {
        case saved
        case pending
        case failed(String)
    }

    public private(set) var page: Page?
    public private(set) var breadcrumbs: [Page] = []
    public private(set) var text = ""
    public private(set) var selection: Range<Int> = 0..<0
    public private(set) var document = MarkdownParser.standard.parse("")
    /// Styling for the whole text, with the syntax under the selection revealed.
    public private(set) var spans: [StyleSpan] = []
    public private(set) var subpageRows: [SubpageRow] = []
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
    private var children: [Page] = []
    private var savedLinks: Set<GlossLink> = []
    /// The debounce timer for the next save.
    private var saveTask: Task<Void, Never>?
    /// Writes run one after another, each writing the text current when it runs, so the newest
    /// text always lands last.
    private var writeChain: Task<Void, Never>?
    private var dismissedSlashAt: Int?
    private var generation = 0

    public init(services: GlossServices, slashCommands: SlashCommandRegistry? = nil, saveDelay: Duration = .milliseconds(500)) {
        self.services = services
        self.slashCommands = slashCommands ?? SlashCommandRegistry.standard(pages: services.pages)
        self.saveDelay = saveDelay
    }

    public var isDirty: Bool { saveState == .pending }

    // MARK: Loading

    public func load(_ page: Page) async {
        await flushSave()
        self.page = page
        text = page.body
        selection = 0..<0
        slashMenu = nil
        dismissedSlashAt = nil
        saveState = .saved
        savedLinks = NotesStyler.glossLinks(in: MarkdownParser.standard.parse(page.body))
        breadcrumbs = (try? await services.pages.breadcrumbs(to: page.id)) ?? [page]
        await refreshContext()
    }

    /// Picks up a change made elsewhere (the CLI, another window). Unsaved local edits win: they
    /// are saved over it, the way a second save from another app would be.
    public func pageChangedExternally() async {
        guard let id = page?.id, !isDirty, let fresh = try? await services.pages.page(id) else { return }
        guard fresh.trash == nil else { page = nil; return }
        if fresh.body != text {
            text = fresh.body
            selection = clamp(selection)
        }
        page = fresh
        savedLinks = NotesStyler.glossLinks(in: MarkdownParser.standard.parse(fresh.body))
        await refreshContext()
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
        spans = SyntaxReveal.apply(baseSpans, selection: selection)
        activeFormats = FormatBar.activeItems(in: document, selection: selection)
        updateSlashMenu()
    }

    // MARK: Commands (each returns an edit for the text view to apply)

    public func run(_ command: any MarkdownEditCommand) -> EditResult? {
        command.edit(document, selection: selection)
    }

    /// Return: continue or end a list or quote; nil means "insert a plain newline".
    public func returnKey() -> EditResult? {
        ListContinuation.newline(in: document, selection: selection)
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

    public func isTaskBox(at offset: Int) -> Bool {
        TaskToggle.boxRange(in: document, at: offset)?.contains(offset) ?? false
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
        let id = itemID ?? menu.items[safe: menu.selectedIndex]?.id
        guard let command = slashCommands.commands.first(where: { $0.id == id }) else { return nil }
        slashMenu = nil
        let result = try await slashCommands.run(command, trigger: menu.trigger, in: document, page: page.id)
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
        guard let page, saveState == .pending else { return }
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
            switch try? await services.links.resolve(link) {
            case .inTrash?: statuses[link] = .inTrash
            case .missing?, nil: statuses[link] = .missing
            default: statuses[link] = .live
            }
        }
        styler = NotesStyler(statuses: statuses)
        reparse()
    }

    private func reparse() {
        document = MarkdownParser.standard.parse(text)
        subpageRows = SubpageRows.rows(in: document, children: children)
        let placed = Set(subpageRows.map(\.pageID))
        unplacedChildren = children.filter { !placed.contains($0.id) }
        baseSpans = styler.spans(for: document, subpageRows: subpageRows)
        spans = SyntaxReveal.apply(baseSpans, selection: selection)
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

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
