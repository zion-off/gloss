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
    private var observers: [NSObjectProtocol] = []

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
    }

    func invalidate() async {
        // There is no plural removeObservers (review 6): one call per observer token.
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        pdfView.delegate = nil
        pdfView.pageOverlayViewProvider = nil
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
        self.document = pdf
        pageCount = pdf.pageCount
        pdfView.document = pdf
        inbox.post(.opened(toc: Self.toc(of: pdf), openID: openID))
        if let position, (try? PDFReaderTarget(position)) != nil {
            try await go(to: position, flash: false)
        } else if pdfView.currentPage == nil, let first = pdf.page(at: 0) {
            pdfView.go(to: first)
        }
        pageChanged()
    }

    func close() async throws {
        document = nil
        pageCount = 0
        annotations = PDFAnnotationLayout(.init())
        pdfView.document = nil
    }

    func go(to locator: Locator, flash: Bool) async throws {
        let target = try PDFReaderTarget(locator)
        guard let pdf = document, let page = pdf.page(at: min(target.pageIndex, max(pageCount - 1, 0))) else { return }
        switch target {
        case .page(let index):
            if let current = pdfView.currentPage, pdf.index(for: current) != index { pdfView.go(to: page) }
        case .passage(let passage):
            guard let span = passage.pages.min(by: { $0.page < $1.page }),
                  let rect = span.rects.compactMap(PDFPageRect.init).first else { pdfView.go(to: page); return }
            pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: rect.x, y: rect.y)))
        }
        if flash { flashRect(target: target) }
    }

    func turnPage(forward: Bool) async throws {
        if forward { pdfView.goToNextPage(nil) } else { pdfView.goToPreviousPage(nil) }
    }

    func show(_ annotations: ReaderAnnotations) async throws {
        self.annotations = PDFAnnotationLayout(annotations)
        // Overlay views are vended per page; the new layout shows on the next layout pass.
        pdfView.needsDisplay = true
    }

    func clearSelection() async throws {
        pdfView.clearSelection()
    }

    func reveal(searchHit locator: Locator?, text: String) async throws {
        if let locator { try await go(to: locator, flash: true) }
        guard let pdf = document, let hit = pdf.findString(text).first, let page = hit.pages.first else { return }
        pdfView.go(to: hit)
        flashRect(on: page, rect: PDFPageRect(x: hit.bounds(for: page).minX, y: hit.bounds(for: page).minY,
                                              width: hit.bounds(for: page).width, height: hit.bounds(for: page).height))
    }

    // MARK: PDFViewDelegate

    /// Links inside a PDF go out, never navigate the view.
    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        MainActor.assumeIsolated { [weak self] in self?.inbox.post(.externalLink(url)) }
    }

    // MARK: PDFPageOverlayViewProvider

    /// PDFKit's protocol isn't main-actor isolated, but it asks for overlays while laying out
    /// the view, on the main thread; `assumeIsolated` states that (and traps if it's ever wrong).
    nonisolated func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        // `PDFPage` isn't Sendable; it's PDFKit's own object, handed over on the main thread
        // that the assertion below checks, so moving it to the main actor races with nothing.
        nonisolated(unsafe) let page = page
        return MainActor.assumeIsolated { overlay(for: page, in: view) }
    }

    private func overlay(for page: PDFPage, in view: PDFView) -> NSView? {
        guard let pdf = document else { return nil }
        let marks = annotations.marks(on: pdf.index(for: page))
        guard !marks.isEmpty else { return nil }
        return PDFPageOverlay(pdfView: view, page: page, marks: marks,
                              colors: colors, onActivate: { [weak self] highlights, markers, anchor in
            self?.inbox.post(.annotationActivated(highlights: highlights, markers: markers, anchor: anchor))
        })
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
            let bounds = line.bounds(for: page)
            let existing = byPage[index] ?? PDFPageSelection(page: index, ranges: [], rects: [], text: "")
            byPage[index] = PDFPageSelection(page: index, ranges: existing.ranges + ranges,
                                            rects: existing.rects + [PDFPageRect(x: bounds.minX, y: bounds.minY,
                                                                                  width: bounds.width, height: bounds.height)],
                                            text: existing.text.isEmpty ? text : existing.text + " " + text)
        }
        let pages = byPage.keys.sorted().compactMap { byPage[$0] }
        guard let passage = PDFSelectionMapping.passage(from: pages, pageCount: pageCount,
                                                        pageLabel: { pdf.page(at: $0)?.label }) else { return }
        let anchor = anchorRect(for: selection, in: pdf)
        inbox.post(.selectionChanged(passage, anchor: anchor))
    }

    /// The selection's first line, in the reader's top-left-origin coordinates (what popovers
    /// anchor to).
    private func anchorRect(for selection: PDFSelection, in pdf: PDFDocument) -> ReaderRect {
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

    // MARK: Drawing help

    private func flashRect(target: PDFReaderTarget) {
        guard let pdf = document, let page = pdf.page(at: target.pageIndex) else { return }
        let rect: PDFPageRect
        if case .passage(let passage) = target, let span = passage.pages.first,
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
        let inView = pdfView.convert(NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), from: page)
        let flash = PDFFlashView(frame: inView)
        pdfView.addSubview(flash)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak flash] in flash?.removeFromSuperview() }
    }

    static func color(_ css: String) -> NSColor? {
        guard let color = CSSColor(palette: css) else { return nil }
        return NSColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green),
                       blue: CGFloat(color.blue), alpha: CGFloat(color.alpha))
    }

    /// The PDF's own outline as the table of contents; pages without one get none (the sidebar
    /// TOC is milestone 12).
    static func toc(of pdf: PDFDocument) -> [ReaderTocEntry] {
        func entries(_ outline: PDFOutline?, limit: Int) -> [ReaderTocEntry] {
            guard let outline, limit > 0 else { return [] }
            var result: [ReaderTocEntry] = []
            var index = 0
            while let child = outline.child(at: index) {
                if let label = child.label, let destination = child.destination {
                    result.append(ReaderTocEntry(label: label,
                                                 target: PDFReaderPositions.locator(page: destination.page.map { pdf.index(for: $0) } ?? 0)))
                }
                result.append(contentsOf: entries(child, limit: limit - 1))
                index += 1
            }
            return result
        }
        return entries(pdf.outlineRoot, limit: 2)
    }
}

/// The overlay for one page: highlights filled, markers underlined, clicks on either reported.
/// Transparent to clicks outside its marks (text selection underneath keeps working).
@MainActor
final class PDFPageOverlay: NSView {
    private weak var pdfView: PDFView?
    private let page: PDFPage
    private let marks: [PDFAnnotationLayout.Mark]
    private let colors: ReaderColors
    private let onActivate: @MainActor ([HighlightID], [LinkTargetID], ReaderRect) -> Void

    init(pdfView: PDFView, page: PDFPage, marks: [PDFAnnotationLayout.Mark],
         colors: ReaderColors, onActivate: @escaping @MainActor ([HighlightID], [LinkTargetID], ReaderRect) -> Void) {
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
                let inView = pdfView.convert(NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), from: page)
                if case .marker = mark.kind {
                    // A thin underline rather than a fill, so the text stays readable.
                    NSRect(x: inView.minX, y: inView.minY, width: inView.width, height: 2).fill()
                } else {
                    inView.fill()
                }
            }
        }
    }

    /// Only the marks take clicks; everything else falls through to the PDF underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let pdfView, let hit = hit(point: point, in: pdfView) else { return nil }
        return hit ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let pdfView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inPage = pdfView.convert(point, to: page)
        var highlights: [HighlightID] = [], markers: [LinkTargetID] = []
        for mark in marks where mark.rects.contains(where: { $0.contains(x: inPage.x, y: inPage.y, slop: 2) }) {
            switch mark.kind {
            case .highlight(let id, _): if !highlights.contains(id) { highlights.append(id) }
            case .marker(let id): if !markers.contains(id) { markers.append(id) }
            }
        }
        guard !highlights.isEmpty || !markers.isEmpty else { return }
        // Anchor the popover to the clicked mark's rect, in the reader's coordinates.
        let mark = marks.first { $0.rects.contains { $0.contains(x: inPage.x, y: inPage.y, slop: 2) } }
        let rect = mark?.rects.first { $0.contains(x: inPage.x, y: inPage.y, slop: 2) }
            ?? PDFPageRect(x: inPage.x, y: inPage.y, width: 1, height: 1)
        let inView = pdfView.convert(NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), from: page)
        onActivate(highlights, markers, PDFReaderSession.readerRect(inView, in: pdfView))
    }

    private func hit(point: NSPoint, in pdfView: PDFView) -> Bool? {
        let inPage = pdfView.convert(point, to: page)
        return marks.contains { mark in mark.rects.contains { $0.contains(x: inPage.x, y: inPage.y, slop: 2) } }
    }

    static func color(for color: HighlightColor, in colors: ReaderColors) -> NSColor? {
        let name = ReaderColorName(color)
        let css: String?
        switch name {
        case .yellow: css = colors.highlights.yellow
        case .green: css = colors.highlights.green
        case .blue: css = colors.highlights.blue
        case .pink: css = colors.highlights.pink
        case .purple: css = colors.highlights.purple
        }
        return PDFReaderSession.color(css ?? "")
    }
}

/// The flash outline over a revealed target.
@MainActor
final class PDFFlashView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: -1, dy: -1))
        path.lineWidth = 2
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
