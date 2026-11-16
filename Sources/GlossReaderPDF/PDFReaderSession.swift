import AppKit
import PDFKit
import GlossCore
import GlossReaderBridge
import GlossReaderKit
import GlossReaderPDFSupport

/// The PDF engine: PDFKit in a `PDFView`. One object is the session, the driver and the page
/// overlay provider — there is no bridge, so the parts stay together. Everything that can be
/// pure lives in `GlossReaderPDFSupport` (Linux-tested); this file only measures, draws and
/// forwards.
@MainActor
final class PDFReaderSession: NSObject, ReaderSession, ReaderDriving, SearchHighlighting, ThemeColorsApplying, PDFViewDelegate,
                              PDFPageOverlayViewProvider {
    var view: NSView { pdfView }
    var driver: any ReaderDriving { self }
    var pageColor: NSColor { pdfView.backgroundColor }

    private let pdfView = PDFView(frame: .zero)
    private let inbox: ReaderEventInbox
    private let library: LibraryService
    private var document: PDFDocument?
    private var pageCount = 0
    private var annotations = PDFAnnotationLayout(.init())
    private var colors: ReaderColors
    private var observers: [any NSObjectProtocol] = []
    /// Watches for the mouse button coming up, which reports a selection dragged out with it.
    private var mouseUpMonitor: Any?
    /// A selection made while the button was down, waiting for it to come up.
    private var selectionHeld = false
    /// Where the button came up over a held selection (the reader's coordinates), for the
    /// popover to point at; set only until that selection is reported.
    private var releasePoint: SelectionAnchor.Point?
    /// The overlays PDFKit is showing, by page index: a new set of annotations reaches the
    /// pages already on screen through these (PDFKit only asks for an overlay once per page).
    private var overlays: [Int: PDFPageOverlay] = [:]
    /// Passages pinned by their words (`gloss link`), found in this document's pages.
    private var quotes = PDFQuoteResolver()
    /// The open document's outline, so each relocation names the entry being read.
    private var toc: [ReaderTocEntry] = []
    /// The search session's matches, collected as the background find finds them; shown softly
    /// once the find ends, so a partial page's worth never flickers in.
    private var searchMatches: [PDFSelection] = []
    /// The session's query a find is (or was last) running for; nil with no session on this book.
    private var searchQuery: String?
    /// A hit with no locator, waiting for the running find's matches to land.
    private var pendingRevealText: String?
    /// Bumped by every session change: a find's end only lands if it is still the newest
    /// (a newer query, a clear, another book).
    private var searchGeneration = 0
    /// The generation of the find that is running, or that just ended.
    private var findGeneration = 0

    init(library: LibraryService, appearance: ReaderAppearance,
         deliver: @escaping @MainActor @Sendable (ReaderEngineEvent) async -> Void) {
        self.library = library
        self.colors = Self.pageColors(appearance.colors)
        self.inbox = ReaderEventInbox(deliver: deliver)
        super.init()

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.delegate = self
        pdfView.pageOverlayViewProvider = self
        pdfView.backgroundColor = Self.color(appearance.colors.background) ?? .textBackgroundColor

        // The Swift spelling of these two names is the one the importer gives the ObjC
        // constants; the docs JSON only carries the extern.
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionChanged() }
        })
        // A background find reports each match and its end as notifications. They are observed
        // on the main queue rather than through PDFDocumentDelegate: nothing documents which
        // thread the delegate is called on, and a main-queue observer is delivered on the main
        // thread whatever thread PDFKit posts from. The Swift spellings are the importer's; the
        // docs JSON only carries the externs, and the match payload's key comes from the SDK
        // header (PDFDocumentFoundSelection).
        observers.append(NotificationCenter.default.addObserver(forName: .PDFDocumentDidFindMatch, object: nil, queue: .main) { [weak self] note in
            // The match is taken out of the notification before the isolated hop: the note is
            // main-queue-delivered but not Sendable, the selection it hands over is.
            nonisolated(unsafe) let match = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection
            MainActor.assumeIsolated { self?.collectMatch(match) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .PDFDocumentDidEndFind, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.findEnded() }
        })

        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            let window = event.window
            let location = event.locationInWindow
            MainActor.assumeIsolated { self?.mouseCameUp(in: window, at: location) }
            return event
        }
        // PDFKit has no page to load, so the session can take commands at once. The controller
        // holds every `open` back until it hears this (the EPUB page says it from script).
        inbox.post(.ready)
    }

    /// A PDF's pages are white paper whatever the theme (only the space around them is
    /// themed), so its highlights take the white page's shades.
    private static func pageColors(_ theme: ReaderColors) -> ReaderColors {
        var colors = theme
        colors.highlights = AppearanceStyler.pageHighlights(for: .light)
        return colors
    }

    // MARK: ThemeColorsApplying

    /// A theme changed in settings: the space around the pages and the marks on pages already
    /// shown follow it at once.
    func apply(_ theme: ReaderColors) {
        colors = Self.pageColors(theme)
        pdfView.backgroundColor = Self.color(theme.background) ?? .textBackgroundColor
        for overlay in overlays.values { overlay.colors = colors }
    }

    func invalidate() async {
        // There is no plural removeObservers: one call per observer token.
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        mouseUpMonitor = nil
        pdfView.delegate = nil
        pdfView.pageOverlayViewProvider = nil
        overlays = [:]
        await inbox.closeAndDrain()
    }

    // MARK: ReaderDriving

    func open(_ document: Document, at position: Locator?, openID: Int) async throws {
        let data: Data
        do { data = try await library.fileData(of: document.id) }
        catch { inbox.post(.openFailed("couldn't read the pdf", openID: openID)); return }
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
            inbox.post(.openFailed("this pdf wouldn't open", openID: openID))
            return
        }
        overlays = [:]
        quotes = PDFQuoteResolver()
        searchMatches = []
        searchGeneration += 1
        searchQuery = nil
        pdfView.highlightedSelections = nil  // the previous book's, until the first find ends
        self.document = pdf
        pageCount = pdf.pageCount
        pdfView.document = pdf
        toc = Self.toc(of: pdf)
        inbox.post(.opened(toc: toc, openID: openID))
        // A position this engine can't read (another engine's, or malformed) opens at the top.
        if let position, (try? PDFReaderTarget(position)) != nil {
            try await go(to: position)
        } else if let first = pdf.page(at: 0) {
            pdfView.go(to: first)
        }
        pageChanged()
    }

    func close() async throws {
        document?.cancelFindString()
        searchMatches = []
        searchGeneration += 1
        searchQuery = nil
        emphasisedMatch = nil
        pdfView.highlightedSelections = nil
        document = nil
        pageCount = 0
        toc = []
        annotations = PDFAnnotationLayout(.init())
        overlays = [:]
        quotes = PDFQuoteResolver()
        pdfView.document = nil
    }

    func go(to locator: Locator) async throws {
        if let fallback = PDFQuoteResolver.fallback(for: locator) {
            // Words the page doesn't have (any more) still land on their page.
            guard let passage = resolvedQuote(locator) else { return try await go(to: fallback) }
            return try await go(to: passage)
        }
        let target = try PDFReaderTarget(locator)
        guard let pdf = document, let page = pdf.page(at: clamped(target.pageIndex)) else { return }
        switch target {
        case .page(let index):
            if pdfView.currentPage.map({ pdf.index(for: $0) }) != index { pdfView.go(to: page) }
        case .passage(let passage):
            guard let span = passage.pages.min(by: { $0.page < $1.page }),
                  let rect = span.rects.compactMap(PDFPageRect.init).first else { pdfView.go(to: page); break }
            // The top of the passage's first line (page space is bottom-left: maxY is the top).
            pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: rect.x, y: rect.y + rect.height)))
        }
    }

    func turnPage(forward: Bool) async throws {
        if forward { pdfView.goToNextPage(nil) } else { pdfView.goToPreviousPage(nil) }
    }

    func show(_ annotations: ReaderAnnotations) async throws {
        self.annotations = PDFAnnotationLayout(resolvingQuotes(in: annotations))
        // PDFKit asks for each page's overlay once; the pages on screen get the new marks here
        // (a link made with ⌘K must show its marker without scrolling away and back, review 6).
        for (index, overlay) in overlays {
            overlay.marks = self.annotations.marks(on: index)
        }
    }

    func clearSelection() async throws {
        pdfView.clearSelection()
    }

    // MARK: The search session

    /// Shows every match of `query` in the document softly, in the background: `beginFindString`
    /// searches off the main thread (a huge pdf never blocks it) and the session collects the
    /// matches as the delegate, showing them when the find ends. A newer call cancels the last
    /// find and drops what it had found. Nil clears them (and the current one).
    func setSearchHighlights(_ query: String?) async throws {
        guard let pdf = document, let query, !query.isEmpty else {
            stopFinding()
            return
        }
        pdf.cancelFindString()  // a find still running for an earlier query
        searchGeneration += 1
        findGeneration = searchGeneration
        searchQuery = query
        pdf.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    /// The running find's newest match (from the find notification).
    private func collectMatch(_ instance: PDFSelection?) {
        guard findGeneration == searchGeneration, let instance else { return }
        searchMatches.append(instance)
    }

    /// The background find ended: the matches it collected become the soft highlights. A find
    /// that was superseded (or whose document closed) never lands.
    private func findEnded() {
        guard let pdf = document, pdfView.document === pdf, findGeneration == searchGeneration else { return }
        let matches = searchMatches
        searchMatches = []
        pdfView.highlightedSelections = matches.isEmpty ? nil : matches
        if let text = pendingRevealText {
            pendingRevealText = nil
            if let match = firstCollectedMatch(of: text) { revealMatch(match) }
        }
    }

    /// Cancels a running find and forgets its matches (a newer query, a clear, a close). The
    /// user's own text selection is not the session's to clear: only the match the session
    /// emphasised goes.
    private func stopFinding() {
        searchGeneration += 1
        searchMatches = []
        pendingRevealText = nil
        searchQuery = nil
        document?.cancelFindString()
        pdfView.highlightedSelections = nil
        if let emphasised = emphasisedMatch, pdfView.currentSelection === emphasised {
            pdfView.clearSelection()
        }
        emphasisedMatch = nil
    }

    /// The match the session emphasised (its current hit), to take back on clear.
    private var emphasisedMatch: PDFSelection?
    /// While the session sets the current match, PDFKit reports it as a selection change; the
    /// selection popover must not open for it.
    private var isEmphasisingSearchMatch = false

    /// Emphasises the current hit: PDFKit draws the current selection in its stronger find
    /// style, on top of the soft highlights. The selection it sets is the session's, not the
    /// user's: the change it triggers is swallowed, so no selection popover opens and ⌘K is
    /// not offered against a search match.
    private func emphasise(_ selection: PDFSelection) {
        emphasisedMatch = selection
        isEmphasisingSearchMatch = true
        pdfView.currentSelection = selection
        Task { @MainActor in self.isEmphasisingSearchMatch = false }
    }

    /// A search hit: its own occurrence on its own page when it has a locator (search chunks
    /// are pages); the document's first occurrence only when it has none. The hit becomes the
    /// current selection, which PDFKit draws in its stronger find style over the soft ones.
    func reveal(searchHit locator: Locator?, text: String) async throws {
        guard let pdf = document else { return }
        if let locator {
            let target = try PDFReaderTarget(locator)
            if let page = pdf.page(at: clamped(target.pageIndex)),
               let match = page.string.flatMap({ PDFTextMatch.range(of: text, in: $0) }),
               let selection = page.selection(for: NSRange(location: match.lowerBound, length: match.count)) {
                pdfView.go(to: selection)
                emphasise(selection)
            } else {
                try await go(to: locator)
            }
            return
        }
        // No locator at all: prefer a match the session's background find already collected
        // (the hit's query is the session's); a find still running holds this until its matches
        // land (`findEnded`), and only a book with no session on it falls back to the
        // synchronous find, the one call of its kind left (nothing else is searching it).
        if let match = firstCollectedMatch(of: text) {
            revealMatch(match)
            return
        }
        if searchQuery != nil {
            pendingRevealText = text
            return
        }
        guard let hit = pdf.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive]).first else { return }
        revealMatch(hit)
    }

    /// A collected match whose text is the hit's, if the session's find gathered one.
    private func firstCollectedMatch(of text: String) -> PDFSelection? {
        searchMatches.first { $0.string?.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private func revealMatch(_ match: PDFSelection) {
        pdfView.go(to: match)
        emphasise(match)
    }

    private func clamped(_ index: Int) -> Int { min(max(index, 0), max(pageCount - 1, 0)) }

    // MARK: Quote locators

    /// The passage locator for a `pdf-quote` locator: its words found in the page's text, their
    /// lines measured by PDFKit (the portable resolver does the rest and remembers it).
    private func resolvedQuote(_ locator: Locator) -> Locator? {
        guard let pdf = document else { return nil }
        return quotes.resolve(locator, pageText: { $0 >= 0 && $0 < pdf.pageCount ? pdf.page(at: $0)?.string : nil }, lineRects: { Self.lineRects(in: pdf, page: $0, range: $1) })
    }

    private func resolvingQuotes(in annotations: ReaderAnnotations) -> ReaderAnnotations {
        guard let pdf = document else { return annotations }
        return quotes.resolve(annotations, pageText: { $0 >= 0 && $0 < pdf.pageCount ? pdf.page(at: $0)?.string : nil },
                              lineRects: { Self.lineRects(in: pdf, page: $0, range: $1) })
    }

    /// One rect per line of a UTF-16 range of a page's text, in page space.
    private static func lineRects(in pdf: PDFDocument, page index: Int, range: Range<Int>) -> [PDFPageRect] {
        guard index >= 0, index < pdf.pageCount, let page = pdf.page(at: index),
              let selection = page.selection(for: NSRange(location: range.lowerBound, length: range.count)) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard line.pages.first === page else { return nil }
            return pageRect(line.bounds(for: page))
        }
    }

    // MARK: PDFViewDelegate

    /// Links inside a PDF go out, never navigate the view.
    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        MainActor.assumeIsolated { [weak self] in self?.inbox.post(.externalLink(url)) }
    }

    // MARK: PDFPageOverlayViewProvider

    /// PDFKit's protocol isn't main-actor isolated, but it asks for overlays while laying out
    /// the view, on the main thread; `assumeIsolated` states that (and traps if it's ever wrong).
    /// Every page gets an overlay, marked or not, so marks added later have somewhere to draw.
    nonisolated func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        // `PDFPage` isn't Sendable; it's PDFKit's own object, handed over on the main thread
        // that the assertion below checks, so moving it to the main actor races with nothing.
        nonisolated(unsafe) let page = page
        return MainActor.assumeIsolated { overlay(for: page, in: view) }
    }

    nonisolated func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        MainActor.assumeIsolated {
            if let index = overlays.first(where: { $0.value === overlayView })?.key { overlays[index] = nil }
        }
    }

    private func overlay(for page: PDFPage, in view: PDFView) -> NSView? {
        guard let pdf = document else { return nil }
        let index = pdf.index(for: page)
        let overlay = PDFPageOverlay(pdfView: view, page: page, marks: annotations.marks(on: index),
                                     colors: colors, onActivate: { [weak self] hit, anchor in
            self?.inbox.post(.annotationActivated(highlights: hit.highlights, markers: hit.markers, anchor: anchor))
        })
        overlays[index] = overlay
        return overlay
    }

    // MARK: Events

    private func pageChanged() {
        guard let pdf = document else { return }
        let index = pdfView.currentPage.map { pdf.index(for: $0) } ?? 0
        let location = PDFReaderPositions.location(page: index, pageCount: pageCount,
                                                   pageLabel: pdf.page(at: index)?.label, toc: toc)
        inbox.post(.relocated(location))
    }

    /// The button came up: a selection held while it was down is final now. Reported after the
    /// view has handled the mouse-up, which may still change the selection.
    private func mouseCameUp(in window: NSWindow?, at windowPoint: NSPoint) {
        guard selectionHeld, window === pdfView.window else { return }
        let point = Self.readerRect(NSRect(origin: pdfView.convert(windowPoint, from: nil), size: .zero), in: pdfView)
        releasePoint = SelectionAnchor.Point(x: point.x, y: point.y)
        Task { @MainActor [weak self] in
            guard let self, self.selectionHeld else { return }
            self.selectionChanged()
        }
    }

    private func selectionChanged() {
        guard !isEmphasisingSearchMatch else { return }  // the search session's, not the user's
        guard let pdf = document else { return }
        guard let selection = pdfView.currentSelection,
              let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            selectionHeld = false
            releasePoint = nil
            inbox.post(.selectionCleared)
            return
        }
        // A selection still being dragged out is reported when the button comes up, like the
        // system's edit menus: the popover must not open under the pointer mid-drag.
        if NSEvent.pressedMouseButtons & 1 != 0 {
            selectionHeld = true
            return
        }
        selectionHeld = false
        let pointer = releasePoint
        releasePoint = nil
        // Group the selection's lines into pages (the portable mapping does the rest).
        var byPage: [Int: PDFPageSelection] = [:]
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first, let text = line.string else { continue }
            let index = pdf.index(for: page)
            let ranges = (0..<line.numberOfTextRanges(on: page)).compactMap { offset -> Range<Int>? in
                let nsrange = line.range(at: offset, on: page)
                guard nsrange.length > 0 else { return nil }
                return nsrange.location..<(nsrange.location + nsrange.length)
            }
            let existing = byPage[index] ?? PDFPageSelection(page: index, ranges: [], rects: [], text: "")
            byPage[index] = PDFPageSelection(page: index, ranges: existing.ranges + ranges,
                                            rects: existing.rects + [Self.pageRect(line.bounds(for: page))],
                                            text: existing.text.isEmpty ? text : existing.text + " " + text)
        }
        let pages = byPage.keys.sorted().compactMap { byPage[$0] }
        guard let passage = PDFSelectionMapping.passage(from: pages, pageCount: pageCount,
                                                        pageLabel: { pdf.page(at: $0)?.label }) else { return }
        inbox.post(.selectionChanged(passage, anchor: anchorRect(for: selection, pointer: pointer)))
    }

    /// Where the popover points (`SelectionAnchor`), in the reader's top-left-origin coordinates:
    /// under the pointer on the line it came up nearest, or the end of the last line. PDFKit
    /// doesn't say which way a selection was extended, so a keyboard one is taken as forwards.
    private func anchorRect(for selection: PDFSelection, pointer: SelectionAnchor.Point?) -> ReaderRect {
        let lines = selection.selectionsByLine().compactMap { line -> ReaderRect? in
            guard let page = line.pages.first else { return nil }
            return Self.readerRect(pdfView.convert(line.bounds(for: page), from: page), in: pdfView)
        }
        return SelectionAnchor.rect(lines: lines, pointer: pointer, backward: false) ?? ReaderRect(x: 0, y: 0, width: 0, height: 0)
    }

    /// A rect in `view`'s coordinates, in the reader contract's top-left origin. Whether
    /// `PDFView` is flipped isn't documented, so ask the view rather than assume.
    static func readerRect(_ rect: NSRect, in view: NSView) -> ReaderRect {
        view.isFlipped
            ? ReaderRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            : .fromBottomLeft(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
                              containerHeight: view.bounds.height)
    }

    static func pageRect(_ rect: NSRect) -> PDFPageRect {
        PDFPageRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    static func nsRect(_ rect: PDFPageRect) -> NSRect {
        NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    // MARK: Drawing help

    static func color(_ css: String) -> NSColor? {
        guard let color = CSSColor(palette: css) else { return nil }
        return NSColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green),
                       blue: CGFloat(color.blue), alpha: CGFloat(color.alpha))
    }

    /// The PDF's own outline as the table of contents (bounded: it comes from the file).
    static func toc(of pdf: PDFDocument) -> [ReaderTocEntry] {
        PDFOutlineTOC.entries(root: pdf.outlineRoot,
                              childCount: { $0.numberOfChildren },
                              child: { $0.child(at: $1) },
                              label: { $0.label },
                              page: { $0.destination?.page.map { pdf.index(for: $0) } })
    }
}

/// The overlay for one page: highlights filled, markers underlined, clicks on either reported.
/// Transparent to clicks outside its marks (text selection underneath keeps working).
///
/// Marks are in page space. PDFKit places this view over its page, so its own coordinates are
/// neither the page's nor the PDF view's: everything converts page → PDF view → this view (and
/// back for clicks), never assuming the overlay sits at the PDF view's origin.
@MainActor
final class PDFPageOverlay: NSView {
    private weak var pdfView: PDFView?
    private let page: PDFPage
    var marks: [PDFAnnotationLayout.Mark] {
        didSet { if marks != oldValue { needsDisplay = true } }
    }
    var colors: ReaderColors {
        didSet { if colors != oldValue { needsDisplay = true } }
    }
    private let onActivate: @MainActor (PDFAnnotationLayout.Hit, ReaderRect) -> Void

    init(pdfView: PDFView, page: PDFPage, marks: [PDFAnnotationLayout.Mark],
         colors: ReaderColors, onActivate: @escaping @MainActor (PDFAnnotationLayout.Hit, ReaderRect) -> Void) {
        self.pdfView = pdfView
        self.page = page
        self.marks = marks
        self.colors = colors
        self.onActivate = onActivate
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView else { return }
        for mark in marks {
            let color: NSColor
            switch mark.kind {
            case .highlight(_, let highlight): color = Self.color(for: highlight, in: colors) ?? .controlAccentColor
            case .marker: color = PDFReaderSession.color(colors.marker) ?? .secondaryLabelColor
            }
            color.setFill()
            for rect in mark.rects {
                let local = convert(pdfView.convert(PDFReaderSession.nsRect(rect), from: page), from: pdfView)
                if case .marker = mark.kind {
                    // A thin underline under the line's text rather than a fill, so it stays readable.
                    let underlineY = isFlipped ? local.maxY - 2 : local.minY
                    NSRect(x: local.minX, y: underlineY, width: local.width, height: 2).fill()
                } else {
                    local.fill()
                }
            }
        }
    }

    /// Only the marks take clicks; everything else falls through to the PDF underneath. The
    /// point arrives in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let pdfView, let superview, !marks.isEmpty else { return nil }
        let inPage = pdfView.convert(pdfView.convert(point, from: superview), to: page)
        return PDFAnnotationLayout.hit(marks, x: inPage.x, y: inPage.y) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        guard let pdfView else { return }
        let inPage = pdfView.convert(pdfView.convert(event.locationInWindow, from: nil), to: page)
        guard let hit = PDFAnnotationLayout.hit(marks, x: inPage.x, y: inPage.y) else { return }
        // The popover anchors to the clicked mark's rect, in the reader's coordinates.
        let inView = pdfView.convert(PDFReaderSession.nsRect(hit.rect), from: page)
        onActivate(hit, PDFReaderSession.readerRect(inView, in: pdfView))
    }

    static func color(for color: HighlightColor, in colors: ReaderColors) -> NSColor? {
        let css: String?
        switch ReaderColorName(color) {
        case .yellow: css = colors.highlights.yellow
        case .green: css = colors.highlights.green
        case .blue: css = colors.highlights.blue
        case .pink: css = colors.highlights.pink
        case .purple: css = colors.highlights.purple
        }
        return PDFReaderSession.color(css ?? "")
    }
}

