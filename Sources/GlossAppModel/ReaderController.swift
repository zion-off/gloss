import Foundation
import Observation
import GlossCore
import GlossMarkdown
import GlossNotes
import GlossReaderBridge

/// The reader pane's behaviour, independent of the engine: open at the saved position, keep
/// highlights and note markers drawn, remember where the reader is, track the selection for the
/// link gesture, and answer clicks on highlights and markers.
///
/// Engine events carry no book identity, so every open gets an id the engine echoes in
/// `.opened`. Between asking for a book and the matching `.opened`, events about books
/// (positions, selections, clicks) belong to the previous book and are dropped; so are
/// `.opened` replies to opens that a newer one replaced.
@MainActor @Observable public final class ReaderController {
    /// Pages that link to a clicked marker, shown as a small list to choose from.
    public struct MarkerChoice: Equatable, Sendable {
        public var target: LinkTargetID
        public var pages: [Page]
        public var anchor: ReaderRect
    }

    /// A clicked highlight, for its popover (recolour, delete, add to notes).
    public struct HighlightFocus: Equatable, Sendable {
        public var highlight: Highlight
        public var anchor: ReaderRect
    }

    /// What hovering a note marker shows: the passage it marks, and every note that links to
    /// it with the line that holds the link.
    public struct MarkerHover: Equatable, Sendable {
        public struct ReferringPage: Equatable, Sendable, Identifiable {
            public var page: Page
            /// The line containing the link, trimmed.
            public var snippet: String

            public var id: PageID { page.id }
        }

        /// The marked passage, as stored on the target.
        public var quote: String
        public var pages: [ReferringPage]
    }

    public private(set) var document: Document?
    public private(set) var toc: [ReaderTocEntry] = []
    public private(set) var location: ReaderLocation?
    public private(set) var selection: BookSelection?
    public private(set) var selectionAnchor: ReaderRect?
    public private(set) var markerChoice: MarkerChoice?
    public private(set) var highlightFocus: HighlightFocus?
    public private(set) var errorMessage: String?
    /// The engine can take commands.
    public private(set) var isReady = false
    /// The book in `document` is on screen and its events are taken.
    public private(set) var isShowingBook = false

    /// Opens a notes page at a range (a marker click). Set by the app model.
    public var openNote: @MainActor (PageID, Range<Int>?) async -> Void = { _, _ in }
    /// Opens a web link from the book. Set by the Mac layer (NSWorkspace). Only schemes in
    /// `externalSchemes` get here: a book must not open files or launch apps.
    public var openExternal: @MainActor (URL) -> Void = { _ in }

    /// Link schemes a book may hand to the system.
    public static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    private let services: GlossServices
    private weak var driver: (any ReaderDriving)?
    private var pendingOpen: (document: Document, locator: Locator?)?
    private var pendingFocus: Locator?
    private var positionTask: Task<Void, Never>?
    /// Bumped by every `open`/`close` call, so one that was overtaken while it waited stops.
    private var openRequests = 0
    /// The id of the last open sent to the engine.
    private var lastOpenID = 0
    /// The open whose `.opened` is awaited; nil when none is in flight.
    private var awaitedOpenID: Int?
    /// What the engine was last asked to draw for the book on screen.
    private var shownAnnotations: ReaderAnnotations?

    public init(services: GlossServices) {
        self.services = services
    }

    /// Connects a freshly created engine (a new web view, or one reloaded after a crash).
    /// Commands wait until it reports `ready`; then the book reopens where the reader was.
    /// Attaching the engine that is already attached changes nothing.
    public func attach(_ driver: any ReaderDriving) {
        guard driver !== self.driver else { return }
        self.driver = driver
        isReady = false
        stopShowingBook()
        if pendingOpen == nil, let document {
            pendingOpen = (document, location?.locator)
        }
    }

    /// Closes the book (it was trashed or purged, here or from another process).
    public func close() async {
        openRequests += 1
        document = nil
        errorMessage = nil
        pendingOpen = nil
        pendingFocus = nil
        stopShowingBook()
        toc = []
        location = nil
        if isReady { try? await driver?.close() }
    }

    /// Opens a document, at `locator` (a passage) or else at the saved reading position.
    public func open(_ document: Document, at locator: Locator? = nil) async {
        if self.document?.id == document.id, isShowingBook || pendingOpen != nil || awaitedOpenID != nil {
            // Already open or opening: just go to the passage (once the book is there).
            if let locator { await go(to: locator, flash: true) }
            return
        }
        openRequests += 1
        let request = openRequests
        self.document = document
        errorMessage = nil  // a stale error must not speak for this open (review 4)
        stopShowingBook()
        toc = []
        location = nil
        pendingFocus = locator
        // A failed read proves nothing: opening at the start would let the first relocation
        // overwrite the real saved position (review 4). Don't open; the user can retry.
        let saved: Locator?
        do {
            saved = locator == nil ? try await services.library.position(of: document.id)?.locator : nil
        } catch {
            errorMessage = "couldn't open the book just now"
            return
        }
        guard request == openRequests else { return }  // a newer open or a close took over
        pendingOpen = (document, locator ?? saved)
        if isReady { await performPendingOpen() }
    }

    public func handle(_ event: ReaderEngineEvent) async {
        switch event {
        case .ready:
            if isReady {
                // Ready again: the engine reloaded (its web content process restarted) and
                // shows nothing. Reopen where the reader was.
                stopShowingBook()
                if pendingOpen == nil, let document { pendingOpen = (document, location?.locator) }
            }
            isReady = true
            await performPendingOpen()
        case .opened(let toc, let openID):
            guard openID == awaitedOpenID else { return }  // a reply to a replaced open
            awaitedOpenID = nil
            isShowingBook = true
            self.toc = toc
            errorMessage = nil
            await refreshAnnotations()
            if let focus = pendingFocus {
                pendingFocus = nil
                await go(to: focus, flash: true)
            }
        case .openFailed(let message, let openID):
            // Only the open in flight counts; a failure of an open a newer one replaced
            // must not cancel it (review 4).
            guard openID == awaitedOpenID else { return }
            awaitedOpenID = nil
            pendingFocus = nil
            errorMessage = message
        case .relocated(let location):
            guard isShowingBook else { return }
            self.location = location
            savePosition(location)
        case .selectionChanged(let passage, let anchor):
            guard isShowingBook, let document else { return }
            selection = BookSelection(documentID: document.id, passage: passage)
            selectionAnchor = anchor
            highlightFocus = nil
        case .selectionCleared:
            guard isShowingBook else { return }
            selection = nil
            selectionAnchor = nil
        case .annotationActivated(let highlightIDs, let markerIDs, let anchor):
            guard isShowingBook else { return }
            await activate(highlights: highlightIDs, markers: markerIDs, anchor: anchor)
        case .externalLink(let url):
            guard isShowingBook, let scheme = url.scheme?.lowercased(), Self.externalSchemes.contains(scheme) else { return }
            openExternal(url)
        case .failed(let message):
            errorMessage = message
        }
    }

    // MARK: Commands

    /// Goes to a locator in the open book; while the book is still opening, it lands there
    /// once it has.
    public func go(to locator: Locator, flash: Bool = false) async {
        guard isShowingBook else {
            if document != nil { pendingFocus = locator }
            return
        }
        do { try await driver?.go(to: locator, flash: flash) } catch { errorMessage = Self.describe(error) }
    }

    /// Re-opens the current book after a failed open (the placeholder's "try again").
    public func retryOpen() async {
        guard let document, !isShowingBook, pendingOpen == nil, awaitedOpenID == nil else { return }
        await open(document)
    }

    public func turnPage(forward: Bool) async {
        guard isShowingBook else { return }
        try? await driver?.turnPage(forward: forward)
    }

    public func reveal(searchHit locator: Locator?, text: String) async {
        guard isShowingBook else { return }
        do { try await driver?.reveal(searchHit: locator, text: text) } catch { errorMessage = Self.describe(error) }
    }

    /// Redraws highlights and markers from the store (after edits, links, external changes).
    /// Nothing is sent when they didn't change: external changes anywhere in the library land
    /// here, and change records can't say which book they touch (a page in any book may link
    /// into this one).
    public func refreshAnnotations() async {
        guard let document, isShowingBook, let driver else { return }
        let highlights: [Highlight]
        let linked: [LinkedPassage]
        do {
            highlights = try await services.highlights.highlights(in: document.id)
            linked = try await services.links.linkedPassages(in: document.id)
        } catch {
            return  // a failed read proves nothing; keep what is drawn
        }
        let annotations = ReaderAnnotations(highlights: highlights, linkedPassages: linked)
        guard annotations != shownAnnotations, isShowingBook, self.document?.id == document.id else { return }
        shownAnnotations = annotations
        do { try await driver.show(annotations) } catch { shownAnnotations = nil }
    }

    /// Highlights the current selection.
    @discardableResult
    public func highlightSelection(_ color: HighlightColor = .yellow) async throws -> Highlight? {
        guard let selection else { return nil }
        let highlight = try await services.highlights.add(selection.passage, color: color, in: selection.documentID)
        if isShowingBook { try? await driver?.clearSelection() }
        self.selection = nil
        selectionAnchor = nil
        await refreshAnnotations()
        return highlight
    }

    public func recolor(_ id: HighlightID, to color: HighlightColor) async throws {
        let updated = try await services.highlights.recolor(id, to: color)
        if highlightFocus?.highlight.id == id { highlightFocus?.highlight = updated }
        await refreshAnnotations()
    }

    /// Deletes a highlight and returns it, so the caller can offer undo.
    @discardableResult
    public func deleteHighlight(_ id: HighlightID) async throws -> Highlight? {
        let deleted = try await services.highlights.delete(id)
        if highlightFocus?.highlight.id == id { highlightFocus = nil }
        await refreshAnnotations()
        return deleted
    }

    public func restoreHighlight(_ highlight: Highlight) async throws {
        try await services.highlights.restore(highlight)
        await refreshAnnotations()
    }

    /// What hovering `marker` shows; nil when nothing links to it any more.
    public func hover(over marker: LinkTargetID) async -> MarkerHover? {
        guard let target = try? await services.links.linkTarget(marker) else { return nil }
        let referring = (try? await services.links.referringPages(to: marker)) ?? []
        let pages = referring.map { page -> MarkerHover.ReferringPage in
            let body = page.body
            let text = MarkdownText(body)
            let link = LinkRanges.ranges(of: .passage(marker), in: body).first
            let line = text.lines.first { line in link.map { line.overlaps($0) } ?? false }
                ?? link ?? 0..<0
            return MarkerHover.ReferringPage(page: page, snippet: String(text[line]).trimmingCharacters(in: .whitespaces))
        }
        guard !pages.isEmpty else { return nil }
        return MarkerHover(quote: target.passage.quote, pages: pages)
    }

    /// Picks a page from the marker list.
    public func choose(_ page: Page) async {
        guard let choice = markerChoice else { return }
        markerChoice = nil
        await openNote(page.id, LinkRanges.ranges(of: .passage(choice.target), in: page.body).first)
    }

    public func dismissPopovers() {
        markerChoice = nil
        highlightFocus = nil
    }

    /// Waits for the latest position save (tests, and before the window closes).
    public func flushPosition() async {
        while let task = positionTask {
            await task.value
            if positionTask == task { break }
        }
    }

    // MARK: Internals

    private func performPendingOpen() async {
        guard let pending = pendingOpen, let driver else { return }
        pendingOpen = nil
        lastOpenID += 1
        let openID = lastOpenID
        awaitedOpenID = openID
        do {
            try await driver.open(pending.document, at: pending.locator, openID: openID)
            try await services.library.markOpened(pending.document.id)
        } catch {
            // The engine threw instead of reporting `.openFailed` (the web content process died
            // mid-open, a command failed). Unwedge exactly like the event path, or the next
            // open of the same book short-circuits forever (review 5).
            guard openID == awaitedOpenID else { return }  // a newer open already took over
            awaitedOpenID = nil
            pendingFocus = nil
            errorMessage = Self.describe(error)
        }
    }

    /// Stops taking events about the book on screen (another is coming, or none).
    private func stopShowingBook() {
        isShowingBook = false
        awaitedOpenID = nil
        shownAnnotations = nil
        selection = nil
        selectionAnchor = nil
        markerChoice = nil
        highlightFocus = nil
    }

    /// Saves are chained so the newest position always lands last.
    private func savePosition(_ location: ReaderLocation) {
        guard let id = document?.id else { return }
        let previous = positionTask
        let library = services.library
        positionTask = Task {
            await previous?.value
            try? await library.savePosition(location.locator, progression: location.progression, label: location.label, of: id)
        }
    }

    private func activate(highlights: [HighlightID], markers: [LinkTargetID], anchor: ReaderRect) async {
        if !markers.isEmpty {
            var pages: [Page] = []
            var firstTarget = markers[0]
            for marker in markers {
                let referring = (try? await services.links.referringPages(to: marker)) ?? []
                if pages.isEmpty, !referring.isEmpty { firstTarget = marker }
                pages += referring.filter { page in !pages.contains { $0.id == page.id } }
            }
            if pages.count == 1, let page = pages.first {
                let target = markers.first { LinkRanges.ranges(of: .passage($0), in: page.body).isEmpty == false } ?? firstTarget
                await openNote(page.id, LinkRanges.ranges(of: .passage(target), in: page.body).first)
                return
            }
            if pages.count > 1 {
                markerChoice = MarkerChoice(target: firstTarget, pages: pages, anchor: anchor)
                return
            }
        }
        if let id = highlights.first, let highlight = try? await services.highlights.highlight(id) {
            highlightFocus = HighlightFocus(highlight: highlight, anchor: anchor)
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as GlossError: error.description
        case ReaderDrivingError.unsupportedLocator: "the reader can't go there"
        default: "the reader hit a snag"
        }
    }
}
