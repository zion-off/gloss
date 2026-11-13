#if os(macOS)
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
final class PDFReaderSession: NSObject, ReaderSession, ReaderDriving, PDFViewDelegate, PDFPageOverlayViewProvider {
    var view: NSView { pdfView }
    var driver: any ReaderDriving { self }

    private let pdfView = PDFView(frame: .zero)
    private let inbox: ReaderEventInbox
    private let library: LibraryService
    private var document: PDFDocument?
    private var pageCount = 0
    private var annotations = PDFAnnotationLayout(.init())
    private let colors: ReaderColors
    private var observers: [any NSObjectProtocol] = []
    /// The overlays PDFKit is showing, by page index: a new set of annotations reaches the
    /// pages already on screen through these (PDFKit only asks for an overlay once per page).
    private var overlays: [Int: PDFPageOverlay] = [:]
    /// Passages pinned by their words (`gloss link`), found in this document's pages.
    private var quotes = PDFQuoteResolver()

    init(library: LibraryService, appearance: ReaderAppearance,
         deliver: @escaping @MainActor @Sendable (ReaderEngineEvent) async -> Void) {
        self.library = library
        self.colors = appearance.colors
        self.inbox = ReaderEventInbox(deliver: deliver)
        super.init()

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.delegate = self
        pdfView.pageOverlayViewProvider = self
        pdfView.backgroundColor = Self.color(appearance.colors.background) ?? .textBackgroundColor

        // The Swift spelling of these two names is the one the importer gives the ObjC
        // constants; the docs JSON only carries the extern (MAC_API_NOTES.md).
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionChanged() }
        })
        // PDFKit has no page to load, so the session can take commands at once. The controller
        // holds every `open` back until it hears this (the EPUB page says it from script).
        inbox.post(.ready)
    }

    func invalidate() async {
        // There is no plural removeObservers (review 6): one call per observer token.
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
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
        self.document = pdf
        pageCount = pdf.pageCount
        pdfView.document = pdf
        inbox.post(.opened(toc: Self.toc(of: pdf), openID: openID))
        // A position this engine can't read (another engine's, or malformed) opens at the top.
        if let position, (try? PDFReaderTarget(position)) != nil {
            try await go(to: position, flash: false)
        } else if let first = pdf.page(at: 0) {
            pdfView.go(to: first)
        }
        pageChanged()
    }

    func close() async throws {
        document = nil
        pageCount = 0
        annotations = PDFAnnotationLayout(.init())
        overlays = [:]
        quotes = PDFQuoteResolver()
        pdfView.document = nil
    }

    func go(to locator: Locator, flash: Bool) async throws {
        if let fallback = PDFQuoteResolver.fallback(for: locator) {
            // Words the page doesn't have (any more) still land on their page, unflashed.
            guard let passage = resolvedQuote(locator) else { return try await go(to: fallback, flash: false) }
            return try await go(to: passage, flash: flash)
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
        if flash { flashRect(target: target) }
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

    /// A search hit: its own occurrence on its own page when it has a locator (search chunks
    /// are pages); the document's first occurrence only when it has none (review 6).
    func reveal(searchHit locator: Locator?, text: String) async throws {
        guard let pdf = document else { return }
        if let locator {
            let target = try PDFReaderTarget(locator)
            if let page = pdf.page(at: clamped(target.pageIndex)),
               let match = page.string.flatMap({ PDFTextMatch.range(of: text, in: $0) }),
               let selection = page.selection(for: NSRange(location: match.lowerBound, length: match.count)) {
                pdfView.go(to: selection)
                flashRect(on: page, rect: Self.pageRect(selection.bounds(for: page)))
            } else {
                try await go(to: locator, flash: true)
            }
            return
        }
        guard let hit = pdf.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive]).first,
              let page = hit.pages.first else { return }
        pdfView.go(to: hit)
        flashRect(on: page, rect: Self.pageRect(hit.bounds(for: page)))
    }

    private func clamped(_ index: Int) -> Int { min(max(index, 0), max(pageCount - 1, 0)) }

    // MARK: Quote locators

    /// The passage locator for a `pdf-quote` locator: its words found in the page's text, their
    /// lines measured by PDFKit (the portable resolver does the rest and remembers it).
    private func resolvedQuote(_ locator: Locator) -> Locator? {
        guard let pdf = document else { return nil }
        return quotes.resolve(locator, pageText: { pdf.page(at: $0)?.string }, lineRects: { Self.lineRects(in: pdf, page: $0, range: $1) })
    }

    private func resolvingQuotes(in annotations: ReaderAnnotations) -> ReaderAnnotations {
        guard let pdf = document else { return annotations }
        return quotes.resolve(annotations, pageText: { pdf.page(at: $0)?.string },
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
                                                   pageLabel: pdf.page(at: index)?.label)
        inbox.post(.relocated(location))
    }

    private func selectionChanged() {
        guard let pdf = document else { return }
        guard let selection = pdfView.currentSelection,
              let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            inbox.post(.selectionCleared)
            return
        }
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
        inbox.post(.selectionChanged(passage, anchor: anchorRect(for: selection)))
    }

    /// The selection's first line, in the reader's top-left-origin coordinates (what popovers
    /// anchor to).
    private func anchorRect(for selection: PDFSelection) -> ReaderRect {
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            return Self.readerRect(pdfView.convert(line.bounds(for: page), from: page), in: pdfView)
        }
        return ReaderRect(x: 0, y: 0, width: 0, height: 0)
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

    private func flashRect(target: PDFReaderTarget) {
        guard let pdf = document, let page = pdf.page(at: clamped(target.pageIndex)) else { return }
        let rect: PDFPageRect
        if case .passage(let passage) = target, let span = passage.pages.min(by: { $0.page < $1.page }),
           let first = span.rects.compactMap(PDFPageRect.init).first {
            rect = first
        } else {
            let bounds = page.bounds(for: .mediaBox)
            rect = PDFPageRect(x: bounds.minX, y: bounds.midY - 20, width: bounds.width, height: 40)
        }
        flashRect(on: page, rect: rect)
    }

    /// A brief outline over a target, like the reader's flash in the web view.
    private func flashRect(on page: PDFPage, rect: PDFPageRect) {
        let flash = PDFFlashView(frame: pdfView.convert(Self.nsRect(rect), from: page).insetBy(dx: -2, dy: -2))
        pdfView.addSubview(flash)
        Task { @MainActor [weak flash] in
            try? await Task.sleep(for: .seconds(1.5))
            flash?.removeFromSuperview()
        }
    }

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
/// back for clicks), never assuming the overlay sits at the PDF view's origin (review 6).
@MainActor
final class PDFPageOverlay: NSView {
    private weak var pdfView: PDFView?
    private let page: PDFPage
    var marks: [PDFAnnotationLayout.Mark] {
        didSet { if marks != oldValue { needsDisplay = true } }
    }
    private let colors: ReaderColors
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

/// The flash outline over a revealed target (its frame is the target grown by the stroke).
@MainActor
final class PDFFlashView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
