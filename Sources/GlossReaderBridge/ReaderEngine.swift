import Foundation
import GlossCore

// The engine-neutral boundary between the app and a reading engine (foliate-js for EPUB,
// PDFKit for PDF). Engines translate their own events into `ReaderEngineEvent`s and implement
// `ReaderDriving`; everything above (`ReaderController`) never sees an engine's details.

/// A table-of-contents entry, with a locator the engine can go to.
public struct ReaderTocEntry: Hashable, Sendable {
    public var label: String
    public var target: Locator
    public var children: [ReaderTocEntry]

    public init(label: String, target: Locator, children: [ReaderTocEntry] = []) {
        self.label = label
        self.target = target
        self.children = children
    }
}

/// Where the reader is.
public struct ReaderLocation: Hashable, Sendable {
    public var locator: Locator
    /// 0…1 through the book.
    public var progression: Double
    /// "Chapter 1. Loomings", for breadcrumbs and the saved position.
    public var label: String?
    /// "3 pages left in Loomings", for the status line.
    public var progressText: String
    public var atStart: Bool
    public var atEnd: Bool
    /// Pages after this one in the current section (paginated reflowable books only; nil in
    /// scrolled flow, fixed layout and PDFs).
    public var pagesLeftInSection: Int?
    /// The table-of-contents entry being read, as the target its `ReaderTocEntry` carries.
    public var contentsTarget: Locator?

    public init(locator: Locator, progression: Double, label: String?, progressText: String, atStart: Bool = false, atEnd: Bool = false,
                pagesLeftInSection: Int? = nil, contentsTarget: Locator? = nil) {
        self.locator = locator
        self.progression = progression
        self.label = label
        self.progressText = progressText
        self.atStart = atStart
        self.atEnd = atEnd
        self.pagesLeftInSection = pagesLeftInSection
        self.contentsTarget = contentsTarget
    }
}

/// What the book should draw: highlights in their colours, and a separate marker for every
/// passage that live notes link to.
public struct ReaderAnnotations: Hashable, Sendable {
    public struct HighlightMark: Hashable, Sendable {
        public var id: HighlightID
        public var locator: Locator
        public var color: HighlightColor

        public init(id: HighlightID, locator: Locator, color: HighlightColor) {
            self.id = id
            self.locator = locator
            self.color = color
        }
    }

    public struct LinkMark: Hashable, Sendable {
        public var id: LinkTargetID
        public var locator: Locator

        public init(id: LinkTargetID, locator: Locator) {
            self.id = id
            self.locator = locator
        }
    }

    public var highlights: [HighlightMark]
    public var markers: [LinkMark]

    public init(highlights: [HighlightMark] = [], markers: [LinkMark] = []) {
        self.highlights = highlights
        self.markers = markers
    }

    public init(highlights: [Highlight], linkedPassages: [LinkedPassage]) {
        self.highlights = highlights.map { HighlightMark(id: $0.id, locator: $0.passage.locator, color: $0.color) }
        self.markers = linkedPassages.map { LinkMark(id: $0.target.id, locator: $0.target.passage.locator) }
    }
}

/// Something that happened in the engine.
public enum ReaderEngineEvent: Hashable, Sendable {
    /// The engine can take commands.
    case ready
    /// The open with this id finished. Events about the book come after it, never before.
    case opened(toc: [ReaderTocEntry], openID: Int)
    /// The open with this id failed (the book didn't load); nothing is showing.
    case openFailed(String, openID: Int)
    case relocated(ReaderLocation)
    /// The user selected a passage; `anchor` is where to point popovers (view coordinates).
    case selectionChanged(Passage, anchor: ReaderRect)
    case selectionCleared
    /// The user clicked drawn annotations.
    case annotationActivated(highlights: [HighlightID], markers: [LinkTargetID], anchor: ReaderRect)
    case externalLink(URL)
    case failed(String)
}

public enum ReaderDrivingError: Error, Equatable, Sendable {
    case unsupportedLocator(LocatorScheme)
    case notReady
}

/// The commands every engine supports.
///
/// `open` may be called while another book is open: the engine closes it first. Engines
/// answer every `open` with `.opened(openID:)` carrying the id they were given, and stop
/// reporting events about the previous book before they report it.
@MainActor
public protocol ReaderDriving: AnyObject {
    func open(_ document: Document, at position: Locator?, openID: Int) async throws
    /// Closes the open book, if any; the engine shows nothing until the next `open`.
    func close() async throws
    func go(to locator: Locator) async throws
    func turnPage(forward: Bool) async throws
    func show(_ annotations: ReaderAnnotations) async throws
    func clearSelection() async throws
    /// Shows a search hit: the locator when the engine can resolve it, else the first match of
    /// `text` near it.
    func reveal(searchHit locator: Locator?, text: String) async throws
}

/// Engines that reflow text (EPUB) also take reading settings. PDFs don't, so this is a
/// separate capability rather than a no-op on every engine.
@MainActor
public protocol ReflowableAppearanceApplying: AnyObject {
    func apply(_ appearance: ReaderAppearance) async throws
}

/// Engines whose look follows only the theme's colours, not the text settings: a PDF's pages
/// stay white paper, but the space around them and its note markers are themed. Separate from
/// `ReflowableAppearanceApplying` so neither engine ignores most of what it is given.
@MainActor
public protocol ThemeColorsApplying: AnyObject {
    func apply(_ colors: ReaderColors)
}

/// Engines that can show a search session's matches: every match of a query softly, the
/// current one emphasised, all of them cleared together. Engines that can't search skip the
/// capability and the app searches without page highlights.
@MainActor
public protocol SearchHighlighting: ReaderDriving {
    /// Shows every match of `query` in the open book softly (a search session), replacing any
    /// previous one; nil clears them all.
    func setSearchHighlights(_ query: String?) async throws
}
