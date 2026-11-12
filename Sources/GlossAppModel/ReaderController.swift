import Foundation
import Observation
import GlossCore
import GlossNotes
import GlossReaderBridge

/// The reader pane's behaviour, independent of the engine: open at the saved position, keep
/// highlights and note markers drawn, remember where the reader is, track the selection for the
/// link gesture, and answer clicks on highlights and markers.
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

    public private(set) var document: Document?
    public private(set) var toc: [ReaderTocEntry] = []
    public private(set) var location: ReaderLocation?
    public private(set) var selection: BookSelection?
    public private(set) var selectionAnchor: ReaderRect?
    public private(set) var markerChoice: MarkerChoice?
    public private(set) var highlightFocus: HighlightFocus?
    public private(set) var errorMessage: String?
    public private(set) var isReady = false

    /// Opens a notes page at a range (a marker click). Set by the app model.
    public var openNote: @MainActor (PageID, Range<Int>?) async -> Void = { _, _ in }
    /// Opens a web link from the book. Set by the Mac layer (NSWorkspace).
    public var openExternal: @MainActor (URL) -> Void = { _ in }

    private let services: GlossServices
    private weak var driver: (any ReaderDriving)?
    private var pendingOpen: (document: Document, locator: Locator?)?
    private var pendingFocus: Locator?
    private var positionTask: Task<Void, Never>?

    public init(services: GlossServices) {
        self.services = services
    }

    /// Connects the engine the view created. Commands wait until it reports `ready`. Attaching
    /// again (the web view reloaded after a crash) reopens the book where the reader was.
    public func attach(_ driver: any ReaderDriving) {
        self.driver = driver
        isReady = false
        if pendingOpen == nil, let document {
            pendingOpen = (document, location?.locator)
        }
    }

    /// Closes the book (it was trashed or purged, here or from another process).
    public func close() {
        document = nil
        pendingOpen = nil
        pendingFocus = nil
        toc = []
        location = nil
        selection = nil
        selectionAnchor = nil
        markerChoice = nil
        highlightFocus = nil
    }

    /// Opens a document, at `locator` (a passage) or else at the saved reading position.
    public func open(_ document: Document, at locator: Locator? = nil) async {
        if self.document?.id == document.id, isReady, let locator {
            await go(to: locator, flash: true)
            return
        }
        self.document = document
        toc = []
        location = nil
        selection = nil
        markerChoice = nil
        highlightFocus = nil
        pendingFocus = locator
        let saved = locator == nil ? (try? await services.library.position(of: document.id))?.locator : nil
        pendingOpen = (document, locator ?? saved)
        if isReady { await performPendingOpen() }
    }

    public func handle(_ event: ReaderEngineEvent) async {
        switch event {
        case .ready:
            isReady = true
            await performPendingOpen()
        case .opened(let toc):
            self.toc = toc
            errorMessage = nil
            await refreshAnnotations()
            if let focus = pendingFocus {
                pendingFocus = nil
                await go(to: focus, flash: true)
            }
        case .relocated(let location):
            self.location = location
            savePosition(location)
        case .selectionChanged(let passage, let anchor):
            guard let document else { return }
            selection = BookSelection(documentID: document.id, passage: passage)
            selectionAnchor = anchor
            highlightFocus = nil
        case .selectionCleared:
            selection = nil
            selectionAnchor = nil
        case .annotationActivated(let highlightIDs, let markerIDs, let anchor):
            await activate(highlights: highlightIDs, markers: markerIDs, anchor: anchor)
        case .externalLink(let url):
            openExternal(url)
        case .failed(let message):
            errorMessage = message
        }
    }

    // MARK: Commands

    public func go(to locator: Locator, flash: Bool = false) async {
        do { try await driver?.go(to: locator, flash: flash) } catch { errorMessage = Self.describe(error) }
    }

    public func turnPage(forward: Bool) async {
        try? await driver?.turnPage(forward: forward)
    }

    public func reveal(searchHit locator: Locator?, text: String) async {
        do { try await driver?.reveal(searchHit: locator, text: text) } catch { errorMessage = Self.describe(error) }
    }

    /// Redraws highlights and markers from the store (after edits, links, external changes).
    public func refreshAnnotations() async {
        guard let document, isReady, let driver else { return }
        let highlights = (try? await services.highlights.highlights(in: document.id)) ?? []
        let linked = (try? await services.links.linkedPassages(in: document.id)) ?? []
        try? await driver.show(ReaderAnnotations(highlights: highlights, linkedPassages: linked))
    }

    /// Highlights the current selection.
    @discardableResult
    public func highlightSelection(_ color: HighlightColor = .yellow) async throws -> Highlight? {
        guard let selection else { return nil }
        let highlight = try await services.highlights.add(selection.passage, color: color, in: selection.documentID)
        try? await driver?.clearSelection()
        self.selection = nil
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
        do {
            try await driver.open(pending.document, at: pending.locator)
            try await services.library.markOpened(pending.document.id)
        } catch {
            errorMessage = Self.describe(error)
        }
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
