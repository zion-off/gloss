import AppKit
import SwiftUI
import GlossAppModel
import GlossCore
import GlossMarkdown
import GlossNotes

/// The notes sheet's one margin: the editor's text, the page title and breadcrumbs, and the reader
/// card all keep this distance from the sheet's edges and from each other.
public enum NotesEditorMetrics {
    public static let margin: CGFloat = 16
    /// The notes' body text size (Notion's).
    public static let bodySize: CGFloat = 16
    /// The page title above the body: a step above the largest heading (30 pt).
    public static let titleSize: CGFloat = 34
}

/// Keeps the text view and the model in step. The view is the source of truth while the user
/// types; the model restyles and saves. Model-issued edits (format bar, slash menu, key
/// commands) go back through the view's change APIs so undo records them as one step.
@MainActor
final class NotesEditorCoordinator: NSObject, NSTextViewDelegate, NSTextLayoutManagerDelegate {
    private let model: NotesEditorModel
    private let notesTheme = NotesTheme.standard
    private let theme = NotesEditorTheme()
    private weak var textView: NotesTextView?
    private weak var scrollView: NSScrollView?
    private var lastRuns: [StyledRun] = []
    private var displayedPageID: PageID?
    private var displayedSubpageRows: [SubpageRow] = []
    private var displayedSpans: [StyleSpan] = []
    private var lastRevealToken: UUID?
    let actions: NotesEditorActions
    /// The tables drawn as grids, shared with the layout fragments that draw them.
    nonisolated let tableStore = TableGridStore()
    private lazy var tableBuilder = TableGridBuilder(theme: theme, notesTheme: notesTheme)
    /// The grids as last drawn, to tell which ones changed.
    private var drawnTables: [RenderedTable] = []
    private var tableRelayoutPending = false
    /// The search highlights last drawn as rendering attributes, so only what changed moves.
    private var drawnSearchHighlights: [Range<Int>] = []
    private var drawnSearchCurrent: Range<Int>?
    private var cursorRectsPending = false
    /// A divider drag's widths before it began, for its undo step.
    private var widthsBeforeDrag: (ordinal: Int, widths: TableColumnWidths?)?

    /// A `gloss://` link was clicked (the window routes it).
    var openGlossLink: (@MainActor (GlossLink) async -> Void)?
    /// A web link was clicked.
    var openWebLink: (@MainActor (URL) -> Void)?
    /// The slash menu created a page (the window opens it).
    var openPage: (@MainActor (PageID) -> Void)?
    /// The selection's rect in the editor's top-left coordinates, or nil (the format bar anchors to it).
    var selectionRectChanged: ((OverlayRect?) -> Void)?
    /// The open slash menu's slash, in the editor's top-left coordinates, or nil (the menu
    /// anchors to it).
    var slashAnchorChanged: ((SlashAnchor?) -> Void)?
    private var reportedSlashAnchor: SlashAnchor?
    private var settledReportPending = false

    init(model: NotesEditorModel, actions: NotesEditorActions) {
        self.model = model
        self.actions = actions
        super.init()
        actions.coordinator = self
    }

    func makeScrollView() -> NSScrollView {
        let textView = NotesTextView(usingTextLayoutManager: true)
        textView.delegate = self
        textView.textLayoutManager?.delegate = self
        textView.allowsUndo = true
        // Plain text: pastes arrive as plain markdown (no attachments or foreign fonts in the
        // buffer); the storage attributes are ours and presentation only.
        textView.isRichText = false
        // The toolbar search is the only search: the text view's own find bar would be a second
        // mechanism with its own highlights, and its ⌘F would steal the Find menu's.
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false   // markdown source: no smart quotes
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // The text's glyphs sit `NotesEditorMetrics.margin` from every edge of the pane: the
        // container inset makes up the rest after the line fragment padding.
        let padding = textView.textContainer?.lineFragmentPadding ?? 5
        textView.textContainerInset = NSSize(width: NotesEditorMetrics.margin - padding, height: NotesEditorMetrics.margin)
        // No background of its own: the notes are written straight onto the window's sheet.
        textView.drawsBackground = false
        textView.onTextClick = { [weak self] index in self?.textClicked(at: index) ?? false }
        textView.onRowClick = { [weak self] row in
            // The block goes the moment the row is clicked, not when the next page has loaded.
            self?.setRowHover(nil)
            self?.openPage?(row.pageID)
        }
        textView.onFocusChange = { [weak self] focused in
            self?.actions.focusChanged(focused)
            // A table with the caret in it shows its markdown only while there is a caret to edit with.
            self?.model.focusDidChange(focused)
            self?.restyle()
        }
        textView.tableStore = tableStore
        textView.onTableCellClick = { [weak self] table, row, column in self?.cellClicked(table: table, row: row, column: column) }
        textView.onTableCommand = { [weak self] command, table in self?.run(command, onTable: table) }
        textView.onPaste = { [weak self] string in self?.paste(string) ?? false }
        textView.onTableResize = { [weak self] table, fractions, done in self?.resizeColumns(ofTable: table, to: fractions, done: done) }
        textView.onTableResetWidths = { [weak self] table in self?.resetColumnWidths(ofTable: table) }
        textView.onWidthChange = { [weak self] in self?.widthChanged() }
        textView.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
        textView.onHover = { [weak self] point in self?.pointerMoved(to: point) }
        // The pointer left the text, or a floating view covers it: the view under it sets the
        // cursor now, so dropping the row must not put the I-beam back.
        textView.onHoverEnd = { [weak self] in
            self?.hoveredRowID = nil
            self?.setRowHover(nil)
            self?.textView?.hideTableHandles()
        }
        textView.onMouseSelectionEnd = { [weak self] in self?.reportSelection() }
        textView.onHeaderResize = { [weak self] in self?.headerResized() }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // The overlays follow the visible text: recompute their anchors when it moves.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        self.textView = textView
        self.scrollView = scrollView
        install(model.text)
        return scrollView
    }

    /// The breadcrumbs and title above the body, scrolling with it.
    func setHeader(_ content: AnyView) {
        guard let textView else { return }
        if let header = textView.header {
            header.update(content: content)
        } else {
            textView.header = NotesHeaderView(content: content)
        }
    }

    /// The header changed height and the text moved with it: what floats over the text follows.
    private func headerResized() {
        textView?.hideTableHandles()
        setRowHover(nil)
        reportSettledSelectionSoon()
        refreshHoverSoon()
    }

    /// Return in the title: typing goes on at the top of the body.
    func focusBody() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func dismantle() {
        NotificationCenter.default.removeObserver(self)
        textView?.delegate = nil
        actions.isEditing = false
        actions.focusChanged(false)  // the editor is gone: ⌘[ goes back to the reader
        model.focusDidChange(false)
    }

    // MARK: Hover

    /// The subpage row under the pointer; the text view draws its highlight.
    private var hoveredRowID: PageID?

    private func setRowHover(_ hit: (row: SubpageRow, rect: NSRect)?) {
        if hit != nil { NSCursor.pointingHand.set() }
        // AppKit only resets the cursor on entering or leaving the view, so leaving a row by
        // moving within the text must put the I-beam back itself.
        if hit == nil, hoveredRowID != nil { NSCursor.iBeam.set() }
        hoveredRowID = hit?.row.pageID
        textView?.hoverRowRect = hit?.rect
    }

    private func pointerMoved(to point: NSPoint) {
        guard let textView else { return }
        setRowHover(textView.rowHit(at: point))
        let table = textView.tableHit(at: point)
        if let table {
            textView.showTableHandles(for: table)
        } else if !textView.isNearTableHandles(point) {
            textView.hideTableHandles()
        }
    }

    // MARK: Subpage rows

    /// The layout fragment for a paragraph: a subpage block line becomes a row; everything
    /// else draws its text. Neither the requirement nor TextKit's classes are main-actor
    /// isolated, so only the model read hops over: `assumeIsolated` states that TextKit lays out
    /// on the main thread (and crashes loudly if that's ever broken).
    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                                       textLayoutFragmentFor location: any NSTextLocation,
                                       in textElement: NSTextElement) -> NSTextLayoutFragment {
        let paragraph = Self.offsets(of: textElement, in: textLayoutManager)
        // A drawn table's line draws its band of the grid. The store is filled before any change
        // that lays these lines out, and the fragment looks its table up again whenever it draws.
        if let paragraph, tableStore.line(covering: paragraph) != nil {
            let fragment = TableGridFragment(textElement: textElement, range: nil)
            fragment.store = tableStore
            return fragment
        }
        let fragment = SubpageRowFragment(textElement: textElement, range: nil)
        if let paragraph {
            // Dynamic colours resolve against the drawing appearance, which is not the view's while
            // a fragment draws: carry it along (dark mode drew black on black). AppKit objects,
            // touched here on the main thread only.
            nonisolated(unsafe) var appearance: NSAppearance?
            nonisolated(unsafe) var font: NSFont?
            fragment.row = MainActor.assumeIsolated {
                appearance = textView?.effectiveAppearance
                font = theme.baseFont(.body)
                return SubpageRows.row(covering: paragraph, in: model.subpageRows)
            }
            fragment.appearance = appearance
            if let font { fragment.font = font }
        }
        return fragment
    }

    /// Where a paragraph sits in the text, in UTF-16 offsets (nil for anything but a paragraph).
    nonisolated static func offsets(of element: NSTextElement, in manager: NSTextLayoutManager) -> Range<Int>? {
        guard element is NSTextParagraph,
              let content = manager.textContentManager as? NSTextContentStorage,
              let elementRange = element.elementRange else { return nil }
        let document = content.documentRange
        let lower = content.offset(from: document.location, to: elementRange.location)
        let upper = content.offset(from: document.location, to: elementRange.endLocation)
        return lower..<upper
    }

    /// Rows changed without the text changing (a rename from another window): rebuild the
    /// fragments, so their rows pick up new titles.
    func invalidateRows() {
        guard let content = textView?.textContentStorage, let manager = textView?.textLayoutManager else { return }
        manager.invalidateLayout(for: content.documentRange)
    }

    // MARK: NSViewRepresentable sync

    /// Brings the view in line with the model: a new page installs its text, an external
    /// change replaces it, and styling catches up with whatever moved.
    func sync(reveal: NotesReveal?) {
        guard let textView else { return }
        if model.page?.id != displayedPageID {
            displayedPageID = model.page?.id
            install(model.text)
        } else if textView.string != model.text, let storage = textView.textStorage {
            // A change from elsewhere (the cli, another window): keep the model's selection.
            // Not undoable — the user didn't make it — and it must clear any coalescing with
            // what came before.
            textView.undoManager?.removeAllActions()
            textView.breakUndoCoalescing()
            let selection = NSRange(model.selection)
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: model.text)
            storage.endEditing()
            textView.setSelectedRange(selection)
            lastRuns = []  // replaced text has no attributes; the diff must not skip it
            restyle()
        }
        // Only on the page it was meant for, once that page is installed (a marker click may
        // open another page first), and clamped: the text may have changed since.
        if let reveal, reveal.token != lastRevealToken, reveal.pageID == displayedPageID {
            lastRevealToken = reveal.token
            let length = textView.string.utf16.count
            let lower = min(reveal.range.lowerBound, length)
            let range = NSRange(lower..<min(max(lower, reveal.range.upperBound), length))
            if reveal.focusesText { textView.window?.makeFirstResponder(textView) }
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }
        if displayedSubpageRows != model.subpageRows {
            displayedSubpageRows = model.subpageRows
            invalidateRows()
        }
        // The search session's highlights can move without anything else changing (a query
        // typed, a step, the session ending): they are compared here, because nothing else
        // re-renders for them — a query change alters no text and no span the editor tracks.
        if drawnSearchHighlights != model.searchRanges || drawnSearchCurrent != model.searchCurrent {
            applySearchHighlights()
        }
        // Styling can change without the text moving (a link's status flipped in the store,
        // the syntax reveal): restyle then, not only on the next keystroke.
        if displayedSpans != model.spans {
            displayedSpans = model.spans
            restyle()
        }
    }

    private func install(_ text: String) {
        guard let textView, let storage = textView.textStorage else { return }
        // The old page's undo history must not survive the switch: replaying it would edit the
        // new page's buffer.
        textView.undoManager?.removeAllActions()
        setRowHover(nil)  // another page's rows: the old block must not linger
        textView.hideTableHandles()
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        lastRuns = []  // see the external-change branch of sync
        drawnSearchHighlights = []
        drawnSearchCurrent = nil  // the new page's highlights are drawn fresh
        restyle()
        textView.scroll(NSPoint(x: 0, y: 0))
    }

    private func textClicked(at index: Int) -> Bool {
        if model.isTaskBox(at: index), let edit = model.toggleTask(at: index) {
            apply(edit)
            return true
        }
        // Subpage rows are hit by where they're drawn (`NotesTextView.rowHit`), not by index.
        return false
    }

    // MARK: Tables

    /// A click on a drawn cell: the caret goes to the end of the cell's text, so the table shows its
    /// markdown, ready to edit there.
    private func cellClicked(table ordinal: Int, row: Int, column: Int) {
        guard let textView, textView.string == model.text,
              let caret = model.caret(inTable: ordinal, row: row, column: column) else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// A "+" handle or the grid's menu: one edit, one undo step; the caret stays on its text.
    private func run(_ command: TableCommand, onTable ordinal: Int) {
        guard let textView, textView.string == model.text else { return }
        let result = switch command {
        case .addRow: model.addRow(toTable: ordinal)
        case .addColumn: model.addColumn(toTable: ordinal)
        }
        guard let result, let edit = result.coalesced(in: textView.string) else { return }
        let scroll = scrollView?.contentView.bounds.origin
        replaceText(NSRange(edit.range), with: edit.replacement, selecting: NSRange(result.selection), scroll: scroll,
                    undoSelection: textView.selectedRange(), undoScroll: scroll, actionName: command.title)
        refreshHoverSoon()
    }

    /// Replaces text as an undo step of its own that puts back the text, the caret and the scroll
    /// position, and whose redo does the same the other way. The text view's own undo would put
    /// the caret at the change, inside the table (turning it back into markdown), and scroll to it.
    private func replaceText(_ range: NSRange, with replacement: String, selecting selection: NSRange, scroll: NSPoint?,
                             undoSelection: NSRange, undoScroll: NSPoint?, actionName: String) {
        guard let textView, let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        let original = (storage.string as NSString).substring(with: range)
        textView.breakUndoCoalescing()
        // Not through `shouldChangeText`: that is where the text view registers its own undo
        // (typing-style coalescing), and this edit carries the undo step registered below — no
        // toggling `allowsUndo` around it, which only worked while that assumption held. The
        // storage change plus `didChangeText` notify everything the same way (input methods, the
        // model, restyling), so the change is seen exactly as a typed one.
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(selection)
        // The scroll is a top-left origin; layout settling below the change doesn't move it.
        restoreScroll(scroll)
        let inserted = NSRange(location: range.location, length: replacement.utf16.count)
        textView.undoManager?.registerUndo(withTarget: self) { coordinator in
            coordinator.replaceText(inserted, with: original, selecting: undoSelection, scroll: undoScroll,
                                    undoSelection: selection, undoScroll: scroll, actionName: actionName)
        }
        textView.undoManager?.setActionName(actionName)
    }

    private func restoreScroll(_ origin: NSPoint?) {
        guard let origin, let scrollView else { return }
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// A divider drag: the grid follows the pointer, and when the drag ends the widths are stored
    /// as one undo step. The text never changes, so the note isn't marked edited.
    private func resizeColumns(ofTable ordinal: Int, to fractions: [Double], done: Bool) {
        textView?.hideTableHandles()  // the table's height changes under them
        if widthsBeforeDrag?.ordinal != ordinal { widthsBeforeDrag = (ordinal, model.columnWidths(ofTable: ordinal)) }
        model.resizeColumns(ofTable: ordinal, to: fractions)
        restyle()
        guard done else { return }
        let before = widthsBeforeDrag?.widths
        widthsBeforeDrag = nil
        model.saveColumnWidths()
        registerWidthsUndo(ofTable: ordinal, back: before, forward: model.columnWidths(ofTable: ordinal), actionName: "resize columns")
        refreshHoverSoon()
    }

    /// A double-click on a divider: automatic widths again, as one undo step.
    private func resetColumnWidths(ofTable ordinal: Int) {
        let before = model.columnWidths(ofTable: ordinal)
        guard before != nil else { return }
        setColumnWidths(nil, ofTable: ordinal, undoTo: before, actionName: "reset column widths")
    }

    private func setColumnWidths(_ widths: TableColumnWidths?, ofTable ordinal: Int, undoTo previous: TableColumnWidths?, actionName: String) {
        textView?.hideTableHandles()
        model.setColumnWidths(widths, ofTable: ordinal)
        restyle()
        registerWidthsUndo(ofTable: ordinal, back: previous, forward: widths, actionName: actionName)
        refreshHoverSoon()
    }

    private func registerWidthsUndo(ofTable ordinal: Int, back: TableColumnWidths?, forward: TableColumnWidths?, actionName: String) {
        guard back != forward, let textView else { return }
        textView.breakUndoCoalescing()
        textView.undoManager?.registerUndo(withTarget: self) { coordinator in
            coordinator.setColumnWidths(back, ofTable: ordinal, undoTo: forward, actionName: actionName)
        }
        textView.undoManager?.setActionName(actionName)
    }

    /// Plain text pasted: a table goes in on lines of its own with the caret after it.
    private func paste(_ string: String) -> Bool {
        guard let textView, textView.string == model.text else { return false }
        model.selectionDidChange(Self.range(textView.selectedRange))
        guard let result = model.paste(string) else { return false }
        apply(result)
        return true
    }

    /// The edit moved or grew the table under the pointer: show its handles where it is now, once
    /// it's laid out, instead of waiting for the next mouse move.
    private func refreshHoverSoon() {
        Task { @MainActor [weak self] in
            guard let self, let textView = self.textView, let window = textView.window else { return }
            let origin = textView.textContainerOrigin
            textView.textLayoutManager?.ensureLayout(for: textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y))
            self.pointerMoved(to: textView.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    /// Drawn tables fill the width: lay them out again, after the frame change (which happens
    /// during layout, when the text storage must not change).
    private func widthChanged() {
        textView?.hideTableHandles()
        guard !tableRelayoutPending else { return }
        tableRelayoutPending = true
        Task { @MainActor [weak self] in
            self?.tableRelayoutPending = false
            self?.restyle()
            self?.reportSelection()  // the lines wrapped anew: the overlays' anchors moved
        }
    }

    private func appearanceChanged() {
        guard let textView else { return }
        tableStore.replace(drawnTables, appearance: textView.effectiveAppearance)
        for table in drawnTables { invalidateLayout(table.range) }
    }

    private func buildTables() -> [RenderedTable] {
        guard let container = textView?.textContainer else { return [] }
        return tableBuilder.build(model.gridTables, text: model.document.text, spans: model.spans,
                                  containerWidth: container.size.width, padding: container.lineFragmentPadding)
    }

    /// Each drawn table's lines exactly as tall as their bands of the grid, never wrapping. Only
    /// where a line's style differs: lines restyled just now lost theirs to `setAttributes`.
    private func applyTableLineHeights(_ tables: [RenderedTable], in storage: NSTextStorage) {
        for table in tables {
            for (line, height) in zip(table.lines, table.layout.lineHeights) where !line.isEmpty && line.upperBound <= storage.length {
                let style = theme.tableLineStyle(height: CGFloat(height))
                let current = storage.attribute(.paragraphStyle, at: line.lowerBound, effectiveRange: nil) as? NSParagraphStyle
                if current != style { storage.addAttribute(.paragraphStyle, value: style, range: NSRange(line)) }
            }
        }
    }

    /// Lays a stretch of text out again (a table whose grid changed while its lines' attributes
    /// didn't, as on a width change, must draw again).
    private func invalidateLayout(_ range: Range<Int>) {
        guard let textView, let content = textView.textContentStorage, let manager = textView.textLayoutManager,
              let start = content.location(content.documentRange.location, offsetBy: range.lowerBound),
              let end = content.location(content.documentRange.location, offsetBy: range.upperBound),
              let textRange = NSTextRange(location: start, end: end) else { return }
        manager.invalidateLayout(for: textRange)
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        model.textDidChange(textView.string, selection: Self.range(textView.selectedRange))
        restyle()
        setRowHover(nil)  // the rows may have moved; the next pointer move finds them again
        textView.hideTableHandles()
        normalizeTypingAttributes()
        reportSelection()
        // A slash typed on a line the view hasn't laid out yet (it scrolls there after this) has no
        // rect until it has.
        reportSettledSelectionSoon()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView else { return }
        // A delete or paste moves the selection while the view's text has already changed and the
        // model has not heard yet (`textDidChange` follows). Styling or snapping against the
        // model's old text here ran past the new text's end, and the exception was swallowed by
        // AppKit halfway through the edit, leaving the view and the model out of step.
        guard textView.string == model.text else { return }
        // A subpage row is one block: its markdown is hidden under the row, so a caret inside it
        // (an arrow key can land there) would split the link on Return or typing. Snap it to
        // the nearer end of the line.
        let selected = textView.selectedRange
        if selected.length == 0, let row = model.subpageRow(at: selected.location),
           selected.location > row.lineRange.lowerBound, selected.location < row.lineRange.upperBound {
            let nearer = selected.location - row.lineRange.lowerBound < row.lineRange.upperBound - selected.location
            textView.setSelectedRange(NSRange(location: nearer ? row.lineRange.lowerBound : row.lineRange.upperBound, length: 0))
            return  // the move this makes comes back through here and is reported once
        }
        // While the user types, the model heard the new text already; a bare selection move
        // only moves the syntax reveal.
        model.selectionDidChange(Self.range(textView.selectedRange))
        restyle()
        normalizeTypingAttributes()
        reportSelection()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let command: NotesEditorModel.KeyCommand
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): command = .newline
        case #selector(NSResponder.insertTab(_:)): command = .tab
        case #selector(NSResponder.insertBacktab(_:)): command = .backtab
        case #selector(NSResponder.cancelOperation(_:)): command = .cancel
        case #selector(NSResponder.moveUp(_:)): command = .up
        case #selector(NSResponder.moveDown(_:)): command = .down
        default: return false
        }
        switch model.keyCommand(command) {
        case .passThrough:
            return false
        case .handled:
            return true
        case .apply(let edit):
            apply(edit)
            return true
        case .confirmSlashMenu:
            Task { await confirmSlashMenu() }
            return true
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let asURL = link as? URL { url = asURL } else if let asString = link as? String { url = URL(string: asString) } else { url = nil }
        guard let url else { return false }
        if let gloss = GlossLink(string: url.absoluteString) {
            let open = openGlossLink
            Task { await open?(gloss) }
        } else {
            openWebLink?(url)
        }
        return true
    }

    // MARK: Editing

    /// Runs a format command on the current selection, as one undo step.
    func run(_ command: any MarkdownEditCommand) {
        if let result = model.run(command) { apply(result) }
    }

    /// Applies the model's edit through the view's change APIs, so undo records it as one step.
    func apply(_ result: EditResult) {
        guard let textView, let storage = textView.textStorage else { return }
        guard let edit = result.coalesced(in: textView.string) else { return }
        let range = NSRange(edit.range)
        guard textView.shouldChangeText(in: range, replacementString: edit.replacement) else { return }
        storage.replaceCharacters(in: range, with: edit.replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(result.selection))
    }

    func apply(_ result: SlashCommandResult) {
        apply(EditResult(edits: [result.edit], selection: result.selection))
        if let page = result.openPage { openPage?(page) }
    }

    func confirmSlashMenu(itemID: String? = nil) async {
        do {
            if let result = try await model.confirmSlashMenu(itemID: itemID) { apply(result) }
        } catch {
            // The menu is closed and the trigger text is untouched; nothing to roll back.
        }
    }

    // MARK: Styling

    /// Restyles what moved: only the ranges whose runs changed get new attributes, so a cursor
    /// move in a long page doesn't touch the whole layout.
    /// A caret right after hidden text would type in its collapsed font: an empty line after a subpage
    /// row came out a hair high, and clicks below the row landed on it. Typing is always plain.
    private func normalizeTypingAttributes() {
        guard let textView, let storage = textView.textStorage, textView.selectedRange().length == 0 else { return }
        let caret = textView.selectedRange().location
        guard caret > 0, caret <= storage.length else { return }
        let before = storage.attributes(at: caret - 1, effectiveRange: nil)
        let collapsed = ((before[.font] as? NSFont)?.pointSize ?? 12) < 1
        let invisible = (before[.foregroundColor] as? NSColor)?.alphaComponent == 0
        // Right after a drawn table, the line break carries the table line's fixed height.
        let afterTable = model.gridTable(at: caret - 1) != nil
        if collapsed || invisible || afterTable { textView.typingAttributes = theme.attributes(for: TextStyle(font: .body)) }
    }

    private func restyle() {
        guard let textView, let storage = textView.textStorage,
              storage.length == model.text.utf16.count else { return }  // not in step: the next change restyles
        displayedSpans = model.spans
        // The grids first: the attribute changes below lay their lines out, and the fragments
        // TextKit makes for them look their tables up in the store.
        let tables = buildTables()
        let redraw = tables.compactMap { table in
            drawnTables.first { $0.ordinal == table.ordinal }.flatMap { $0.drawsSame(as: table) ? nil : table.range }
        }
        let hadTables = !drawnTables.isEmpty
        drawnTables = tables
        tableStore.replace(tables, appearance: textView.effectiveAppearance)

        let length = model.text.utf16.count
        let runs = notesTheme.runs(for: model.spans, length: length)
        let changed = StyledRunDiff.changedRanges(from: lastRuns, to: runs)
        lastRuns = runs

        storage.beginEditing()
        for range in changed {
            for run in runs where run.range.overlaps(range) {
                storage.setAttributes(theme.attributes(for: run.style), range: NSRange(run.range))
            }
            applyLinkAttributes(in: range)
        }
        applyTableLineHeights(tables, in: storage)
        storage.endEditing()
        for range in redraw { invalidateLayout(range) }
        // Their zones move with any change above them, and go when the tables do.
        if hadTables || !tables.isEmpty { invalidateCursorRectsSoon() }
        applySearchHighlights()
    }

    /// The search session's highlights, as TextKit 2 rendering attributes: soft behind every
    /// match, stronger behind the current one. Rendering attributes draw over the layout's own
    /// attributes without touching the text storage, so the text, the undo stack and the edited
    /// state are untouched, and they follow the model wherever it restyles.
    private func applySearchHighlights() {
        guard let textView, let manager = textView.textLayoutManager, let content = textView.textContentStorage else { return }
        guard textView.string == model.text else { return }  // not in step: the next change redraws
        func textRange(_ range: Range<Int>) -> NSTextRange? {
            guard let start = content.location(content.documentRange.location, offsetBy: range.lowerBound),
                  let end = content.location(content.documentRange.location, offsetBy: range.upperBound) else { return nil }
            return NSTextRange(location: start, end: end)
        }
        // Remove what moved or went, add what is new; the current one last, so it draws on top.
        for range in drawnSearchHighlights + (drawnSearchCurrent.map { [$0] } ?? []) {
            if let textRange = textRange(range) { manager.removeRenderingAttribute(.backgroundColor, for: textRange) }
        }
        let soft = NSColor.unemphasizedSelectedTextBackgroundColor
        let strong = NSColor.selectedTextBackgroundColor
        for range in model.searchRanges where range != model.searchCurrent {
            if let textRange = textRange(range) { manager.setRenderingAttributes([.backgroundColor: soft], for: textRange) }
        }
        if let current = model.searchCurrent, let textRange = textRange(current) {
            manager.setRenderingAttributes([.backgroundColor: strong], for: textRange)
        }
        drawnSearchHighlights = model.searchRanges
        drawnSearchCurrent = model.searchCurrent
    }

    /// The tables' cursor zones follow their tables, once the change is laid out (after this turn
    /// of the run loop, not in the middle of the text view's own change handling).
    private func invalidateCursorRectsSoon() {
        guard !cursorRectsPending else { return }
        cursorRectsPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.cursorRectsPending = false
            guard let textView = self.textView else { return }
            textView.window?.invalidateCursorRects(for: textView)
        }
    }

    /// Clickable links: the `.link` attribute over each link's label (the value is the
    /// destination; gloss destinations route through the app).
    private func applyLinkAttributes(in range: Range<Int>) {
        guard let textView, let storage = textView.textStorage else { return }
        let grids = model.gridTables.map(\.table.range)
        // Not under a drawn table: its markdown is hidden, and a link there would take clicks and
        // show a hand cursor where the grid shows something else.
        for link in LinkScanner.links(in: model.document) where link.labelRange.overlaps(range)
            && !grids.contains(where: { $0.contains(link.range.lowerBound) }) {
            guard let url = URL(string: link.destination) else { continue }
            storage.addAttribute(.link, value: url, range: NSRange(link.labelRange))
        }
    }

    // MARK: Overlays

    /// Where the overlays anchor: the selection's first line, and the slash that opened the
    /// slash menu (not the caret, which moves on as the filter is typed).
    ///
    /// Measured against settled layout. Right after an edit, TextKit 2 places the lines from
    /// estimates until the text view next lays out (the slash came out a line or more above where
    /// it's drawn, and a line not laid out yet has no rect at all), and nothing re-reported once
    /// it had. So the text view lays out first — except from the scroll notification
    /// (`layingOut: false`), which can arrive in the middle of a layout pass; that one is measured
    /// again once the pass is over.
    private func reportSelection(layingOut: Bool = true) {
        guard let textView else { return }
        if layingOut { textView.layoutSubtreeIfNeeded() }
        let selection = textView.selectedRange()
        // The format bar waits for a drag selection to end, like the system's edit menus: shown
        // mid-drag it chased the pointer and could land under it.
        let showsBar = selection.length > 0 && !textView.isSelectingWithMouse
        selectionRectChanged?(showsBar ? overlayRect(for: selection) : nil)
        let slash = model.slashMenu?.trigger.range.lowerBound
        let anchor = slash.flatMap { offset in
            offset < (textView.string as NSString).length
                ? overlayRect(for: NSRange(location: offset, length: 1)).map { SlashAnchor(offset: offset, rect: $0) } : nil
        }
        // Only a move re-renders: typing the filter leaves the slash where it is.
        if anchor != reportedSlashAnchor {
            reportedSlashAnchor = anchor
            slashAnchorChanged?(anchor)
        }
    }

    /// A range's first line in SwiftUI's top-left-origin coordinates of the editor's frame.
    /// Whether the scroll view is flipped is asked, not assumed; the conversion lives in
    /// `OverlayGeometry`, Linux-tested.
    private func overlayRect(for range: NSRange) -> OverlayRect? {
        guard let textView, let scrollView else { return nil }
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        guard screenRect != .zero else { return nil }  // not laid out: no rect, not the screen's corner
        let windowRect = textView.window.map { $0.convertFromScreen(screenRect) } ?? screenRect
        let inView = scrollView.convert(windowRect, from: nil)
        return OverlayGeometry.topLeft(OverlayRect(x: inView.minX, y: inView.minY, width: inView.width, height: inView.height),
                                       inHeight: scrollView.bounds.height, flipped: scrollView.isFlipped)
    }

    @objc private func boundsChanged() {
        reportSelection(layingOut: false)
        reportSettledSelectionSoon()
        refreshHoverFromCurrentPointer()
    }

    /// The anchors once the current layout pass is over, when they can be measured settled.
    /// Unchanged anchors re-render nothing.
    private func reportSettledSelectionSoon() {
        guard !settledReportPending else { return }
        settledReportPending = true
        Task { @MainActor [weak self] in
            self?.settledReportPending = false
            self?.reportSelection()
        }
    }

    /// After a scroll the pointer may not have moved (a trackpad scroll, keyboard scrolling), so
    /// no mouse move will come: recompute the hover from where the pointer is now. The handles
    /// are subviews of the text view and stay glued to their table through the scroll; this only
    /// decides whether they should still show, and hides them once the table has moved away from
    /// under the pointer. Skipped when a floating view owns the pointer, like a mouse move is.
    private func refreshHoverFromCurrentPointer() {
        guard let textView, let window = textView.window else { return }
        let location = window.mouseLocationOutsideOfEventStream
        guard textView.isUnderPointer(windowPoint: location) else { return }
        pointerMoved(to: textView.convert(location, from: nil))
    }

    static func range(_ nsRange: NSRange) -> Range<Int> {
        nsRange.location..<nsRange.location + nsRange.length
    }
}

/// Where the slash menu hangs: the slash's offset in the text (the menu it belongs to) and its
/// rect in the editor's top-left coordinates.
struct SlashAnchor: Equatable {
    var offset: Int
    var rect: OverlayRect
}
