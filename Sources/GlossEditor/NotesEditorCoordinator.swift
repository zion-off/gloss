#if os(macOS)
import AppKit
import GlossAppModel
import GlossCore
import GlossMarkdown
import GlossNotes

/// Keeps the text view and the model in step. The view is the source of truth while the user
/// types; the model restyles and saves. Model-issued edits (format bar, slash menu, key
/// commands) go back through the view's change APIs so undo records them as one step.
@MainActor
final class NotesEditorCoordinator: NSObject, NSTextViewDelegate {
    private let model: NotesEditorModel
    private let theme = NotesEditorTheme()
    private weak var textView: NotesTextView?
    private weak var scrollView: NSScrollView?
    private var lastRuns: [StyledRun] = []
    private var displayedPageID: PageID?
    private var displayedSubpageRows: [SubpageRow] = []
    private var lastRevealToken: UUID?
    let actions: NotesEditorActions

    /// A `gloss://` link was clicked (the window routes it).
    var openGlossLink: (@MainActor (GlossLink) async -> Void)?
    /// A web link was clicked.
    var openWebLink: (@MainActor (URL) -> Void)?
    /// The slash menu created a page (the window opens it).
    var openPage: (@MainActor (PageID) -> Void)?
    /// The selection's rect in the scroll view's coordinates, or nil (the format bar anchors to it).
    var selectionRectChanged: ((NSRect?) -> Void)?
    /// The caret's rect in the scroll view's coordinates, or nil (the slash menu anchors to it).
    var caretRectChanged: ((NSRect?) -> Void)?

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
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false   // markdown source: no smart quotes
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 10)
        textView.backgroundColor = .textBackgroundColor
        textView.onTextClick = { [weak self] index in self?.textClicked(at: index) }
        textView.onFocusChange = { [weak self] focused in self?.actions.isEditing = focused }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
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

    func dismantle() {
        NotificationCenter.default.removeObserver(self)
        textView?.delegate = nil
        actions.isEditing = false
    }

    // MARK: Subpage rows

    /// The layout fragment for a paragraph: a subpage block line becomes a row; everything
    /// else draws its text. The requirement isn't main-actor isolated, but TextKit lays out on
    /// the main thread — `assumeIsolated` states that assumption (crashes loudly if broken).
    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                                       textLayoutFragmentFor location: any NSTextLocation,
                                       in textElement: any NSTextElement) -> NSTextLayoutFragment {
        MainActor.assumeIsolated {
            let fragment = SubpageRowFragment(textElement: textElement, range: nil)
            fragment.row = row(for: fragment, in: textLayoutManager)
            return fragment
        }
    }

    /// The subpage row this fragment covers, if its paragraph is a block line.
    @MainActor private func row(for fragment: NSTextLayoutFragment, in manager: NSTextLayoutManager) -> SubpageRow? {
        guard let paragraph = fragment.textElement as? NSTextParagraph,
              let content = manager.textContentManager as? NSTextContentStorage,
              let elementRange = paragraph.elementRange else { return nil }
        let document = content.documentRange
        let lower = content.offset(from: document.location, to: elementRange.location)
        let upper = content.offset(from: document.location, to: elementRange.endLocation)
        return model.subpageRows.first { $0.lineRange.contains(lower) && $0.lineRange.contains(upper - 1) }
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
        } else if textView.string != model.text {
            // A change from elsewhere (the cli, another window): keep the model's selection.
            let selection = NSRange(model.selection)
            textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: textView.string.utf16.count),
                                                   with: model.text)
            textView.setSelectedRange(selection)
            restyle()
        }
        // Only on the page it was meant for, once that page is installed (a marker click may
        // open another page first), and clamped: the text may have changed since.
        if let reveal, reveal.token != lastRevealToken, reveal.pageID == displayedPageID {
            lastRevealToken = reveal.token
            let length = textView.string.utf16.count
            let lower = min(reveal.range.lowerBound, length)
            let range = NSRange(lower..<min(max(lower, reveal.range.upperBound), length))
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }
        if displayedSubpageRows != model.subpageRows {
            displayedSubpageRows = model.subpageRows
            invalidateRows()
        }
    }

    private func install(_ text: String) {
        guard let textView else { return }
        textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: textView.string.utf16.count), with: text)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        restyle()
        textView.scroll(NSPoint(x: 0, y: 0))
    }

    private func textClicked(at index: Int) -> Bool {
        if model.isTaskBox(at: index), let edit = model.toggleTask(at: index) {
            apply(edit)
            return true
        }
        if let row = model.subpageRow(at: index) {
            openPage?(row.pageID)
            return true
        }
        return false
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        model.textDidChange(textView.string, selection: Self.range(textView.selectedRange))
        restyle()
        reportSelection()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView else { return }
        // While the user types, the model heard the new text already; a bare selection move
        // only moves the syntax reveal.
        model.selectionDidChange(Self.range(textView.selectedRange))
        restyle()
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
        guard let textView else { return }
        let text = textView.string
        guard let edit = result.coalesced(in: text) else { return }
        let range = NSRange(edit.range)
        guard textView.shouldChangeText(in: range, replacementString: edit.replacement) else { return }
        textView.textStorage.replaceCharacters(in: range, with: edit.replacement)
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
    private func restyle() {
        guard let textView else { return }
        let length = model.text.utf16.count
        let runs = theme.runs(for: model.spans, length: length)
        let changed = StyledRunDiff.changedRanges(from: lastRuns, to: runs)
        lastRuns = runs
        guard !changed.isEmpty else { return }

        let storage = textView.textStorage
        storage.beginEditing()
        defer { storage.endEditing() }
        for range in changed {
            for run in runs where run.range.overlaps(range) {
                storage.setAttributes(theme.attributes(for: run.style),
                                       range: NSRange(run.range.clamped(to: 0..<max(length, 1))))
            }
            applyLinkAttributes(in: range)
        }
    }

    /// Clickable links: the `.link` attribute over each link's label (the value is the
    /// destination; gloss destinations route through the app).
    private func applyLinkAttributes(in range: Range<Int>) {
        guard let textView else { return }
        let storage = textView.textStorage
        for link in LinkScanner.links(in: model.document) where link.labelRange.overlaps(range) {
            guard let url = URL(string: link.destination) else { continue }
            storage.addAttribute(.link, value: url, range: NSRange(link.labelRange))
        }
    }

    // MARK: Overlays

    /// Where the overlays anchor, in the scroll view's coordinates.
    private func reportSelection() {
        guard let textView, let scrollView else { return }
        let selection = textView.selectedRange()
        let rect = textView.firstRect(forCharacterRange: selection, actualRange: nil)
        let inView = scrollView.convert(Self.rect(rect, in: textView.window), from: nil)
        selectionRectChanged?(selection.length > 0 ? inView : nil)
        caretRectChanged?(inView)
    }

    @objc private func boundsChanged() {
        reportSelection()
    }

    static func range(_ nsRange: NSRange) -> Range<Int> {
        nsRange.location..<nsRange.location + nsRange.length
    }

    static func rect(_ screenRect: NSRect, in window: NSWindow?) -> NSRect {
        guard let window else { return screenRect }
        return window.convertFromScreen(screenRect)
    }
}
#endif
