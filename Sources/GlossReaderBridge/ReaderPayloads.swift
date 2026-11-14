import Foundation
import GlossCore

// The value types of the reader bridge (twin of `web/src/bridge/protocol.ts`). Every field name matches the
// JSON fixtures in Tests/Fixtures/bridge/, which both sides test against.

/// A rectangle in CSS pixels, relative to the web view's viewport (top-left origin).
public struct ReaderRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

extension ReaderRect {
    /// A rect measured in a bottom-left-origin view (AppKit unflipped, PDF page space after
    /// conversion), in the reader's top-left-origin coordinates — the contract every
    /// `ReaderEngineEvent` anchor follows.
    public static func fromBottomLeft(x: Double, y: Double, width: Double, height: Double,
                                      containerHeight: Double) -> ReaderRect {
        ReaderRect(x: x, y: containerHeight - (y + height), width: width, height: height)
    }
}

/// Reading flow.
public enum ReaderFlow: String, Codable, Sendable {
    case paginated
    case scrolled
}

/// A colour name the reader understands.
public enum ReaderColorName: String, Codable, Hashable, Sendable {
    case yellow, green, blue, pink, purple

    public init(_ color: HighlightColor) {
        self = ReaderColorName(rawValue: color.rawValue) ?? .yellow
    }

    public var highlightColor: HighlightColor { HighlightColor(rawValue: rawValue) ?? .yellow }
}

/// Text direction of the book.
public enum ReaderDirection: String, Codable, Sendable {
    case ltr, rtl
}

/// The colour set the JS side draws with.
public struct ReaderColors: Codable, Hashable, Sendable {
    public struct Highlights: Codable, Hashable, Sendable {
        public var yellow: String
        public var green: String
        public var blue: String
        public var pink: String
        public var purple: String

        public init(yellow: String, green: String, blue: String, pink: String, purple: String) {
            self.yellow = yellow
            self.green = green
            self.blue = blue
            self.pink = pink
            self.purple = purple
        }

        public subscript(color: ReaderColorName) -> String {
            switch color {
            case .yellow: yellow
            case .green: green
            case .blue: blue
            case .pink: pink
            case .purple: purple
            }
        }
    }

    public var background: String
    public var foreground: String
    /// The underline colour for note-link markers.
    public var marker: String
    public var highlights: Highlights

    public init(background: String, foreground: String, marker: String, highlights: Highlights) {
        self.background = background
        self.foreground = foreground
        self.marker = marker
        self.highlights = highlights
    }
}

/// Page geometry the paginator applies as element attributes.
public struct ReaderLayout: Codable, Hashable, Sendable {
    public var margin: Int
    public var gap: Double
    public var maxInlineSize: Int
    public var maxColumnCount: Int

    public init(margin: Int = 48, gap: Double = 0.06, maxInlineSize: Int = 720, maxColumnCount: Int = 2) {
        self.margin = margin
        self.gap = gap
        self.maxInlineSize = maxInlineSize
        self.maxColumnCount = maxColumnCount
    }
}

/// Everything visual the reader needs: flow, injected CSS, layout attributes and colours.
public struct ReaderAppearance: Codable, Hashable, Sendable {
    public var flow: ReaderFlow
    public var css: String
    public var layout: ReaderLayout
    public var colors: ReaderColors

    public init(flow: ReaderFlow, css: String, layout: ReaderLayout, colors: ReaderColors) {
        self.flow = flow
        self.css = css
        self.layout = layout
        self.colors = colors
    }
}

/// A table-of-contents entry.
public struct ReaderTocItem: Codable, Hashable, Sendable {
    public var label: String
    public var href: String
    public var children: [ReaderTocItem]

    public init(label: String, href: String, children: [ReaderTocItem] = []) {
        self.label = label
        self.href = href
        self.children = children
    }

    /// Depth-first, with depth.
    public func walk(depth: Int = 0) -> [(item: ReaderTocItem, depth: Int)] {
        [(self, depth)] + children.flatMap { $0.walk(depth: depth + 1) }
    }
}

// MARK: Command payloads

// Nullable command fields are always sent, as JSON null when empty: the JS validator requires
// the key, and synthesized Codable would leave nil keys out.

public struct ReaderOpenPayload: Codable, Hashable, Sendable {
    /// Echoed by `opened`, so the app can tell which open a reply belongs to.
    public var openID: Int
    public var url: String
    /// The CFI to return to, or nil to start at the beginning (sent as null).
    public var position: String?
    public var appearance: ReaderAppearance

    public init(openID: Int, url: String, position: String?, appearance: ReaderAppearance) {
        self.openID = openID
        self.url = url
        self.position = position
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey { case openID, url, position, appearance }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(openID, forKey: .openID)
        try container.encode(url, forKey: .url)
        try container.encode(position, forKey: .position)
        try container.encode(appearance, forKey: .appearance)
    }
}

/// A passage pinned by its words (an `epub-quote` locator): the glue finds the words in
/// spine section `section` (context first, then the occurrence) and treats the range like a CFI.
public struct ReaderQuoteTarget: Codable, Hashable, Sendable {
    public var section: Int
    public var text: String
    public var prefix: String
    public var suffix: String
    public var occurrence: Int

    public init(section: Int, text: String, prefix: String = "", suffix: String = "", occurrence: Int = 0) {
        self.section = section
        self.text = text
        self.prefix = prefix
        self.suffix = suffix
        self.occurrence = occurrence
    }
}

/// Where `goTo` goes.
public enum ReaderTarget: Codable, Hashable, Sendable {
    case cfi(String)
    case href(String)
    case fraction(Double)
    case quote(ReaderQuoteTarget)

    private enum CodingKeys: String, CodingKey { case cfi, href, fraction, quote }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let cfi = try container.decodeIfPresent(String.self, forKey: .cfi) { self = .cfi(cfi); return }
        if let href = try container.decodeIfPresent(String.self, forKey: .href) { self = .href(href); return }
        if let fraction = try container.decodeIfPresent(Double.self, forKey: .fraction) { self = .fraction(fraction); return }
        if let quote = try container.decodeIfPresent(ReaderQuoteTarget.self, forKey: .quote) { self = .quote(quote); return }
        throw DecodingError.dataCorruptedError(forKey: CodingKeys.cfi, in: container, debugDescription: "empty reader target")
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cfi(let value): try container.encode(value, forKey: .cfi)
        case .href(let value): try container.encode(value, forKey: .href)
        case .fraction(let value): try container.encode(value, forKey: .fraction)
        case .quote(let value): try container.encode(value, forKey: .quote)
        }
    }

    /// A locator's value when the locator comes from this engine.
    public var locatorValue: String? {
        switch self {
        case .cfi(let value): value
        default: nil
        }
    }
}

public struct ReaderGoToPayload: Codable, Hashable, Sendable {
    public var target: ReaderTarget
    /// Briefly outline the destination after arriving.
    public var flash: Bool

    public init(target: ReaderTarget, flash: Bool = false) {
        self.target = target
        self.flash = flash
    }
}

public struct ReaderTurnPagePayload: Codable, Hashable, Sendable {
    public enum Direction: String, Codable, Sendable { case forward, backward }
    public var direction: Direction

    public init(direction: Direction) {
        self.direction = direction
    }
}

public struct ReaderHighlightAnnotation: Codable, Hashable, Sendable {
    public var id: String
    public var cfi: String
    public var color: ReaderColorName

    public init(id: String, cfi: String, color: ReaderColorName) {
        self.id = id
        self.cfi = cfi
        self.color = color
    }
}

/// A note marker, placed by a CFI or, for passages pinned by their words, by a quote the glue
/// resolves to a CFI (exactly one of the two goes on the wire).
public struct ReaderMarkerAnnotation: Codable, Hashable, Sendable {
    public var id: String
    public var cfi: String?
    public var quote: ReaderQuoteTarget?

    public init(id: String, cfi: String) {
        self.id = id
        self.cfi = cfi
    }

    public init(id: String, quote: ReaderQuoteTarget) {
        self.id = id
        self.quote = quote
    }

    private enum CodingKeys: String, CodingKey { case id, cfi, quote }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        cfi = try container.decodeIfPresent(String.self, forKey: .cfi)
        quote = try container.decodeIfPresent(ReaderQuoteTarget.self, forKey: .quote)
        guard (cfi == nil) != (quote == nil) else {
            throw DecodingError.dataCorruptedError(forKey: .cfi, in: container, debugDescription: "a marker needs a cfi or a quote")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(cfi, forKey: .cfi)
        try container.encodeIfPresent(quote, forKey: .quote)
    }
}

/// The complete desired annotation set; the JS side diffs it.
public struct ReaderSetAnnotationsPayload: Codable, Hashable, Sendable {
    public var highlights: [ReaderHighlightAnnotation]
    public var markers: [ReaderMarkerAnnotation]

    public init(highlights: [ReaderHighlightAnnotation] = [], markers: [ReaderMarkerAnnotation] = []) {
        self.highlights = highlights
        self.markers = markers
    }
}

public struct ReaderSearchPayload: Codable, Hashable, Sendable {
    public var query: String
    public init(query: String) { self.query = query }
}

public struct ReaderRevealSearchHitPayload: Codable, Hashable, Sendable {
    /// Sent as null when unknown.
    public var cfi: String?
    /// The spine index to search in; sent as null when unknown.
    public var section: Int?
    public var text: String

    public init(cfi: String? = nil, section: Int? = nil, text: String) {
        self.cfi = cfi
        self.section = section
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case cfi, section, text }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cfi, forKey: .cfi)
        try container.encode(section, forKey: .section)
        try container.encode(text, forKey: .text)
    }
}

public struct ReaderSetAppearancePayload: Codable, Hashable, Sendable {
    public var appearance: ReaderAppearance
    public init(appearance: ReaderAppearance) { self.appearance = appearance }
}

// MARK: Event payloads

public struct ReaderOpenedPayload: Codable, Hashable, Sendable {
    /// The `openID` of the `open` this answers.
    public var openID: Int
    public var toc: [ReaderTocItem]
    public var sectionCount: Int
    public var direction: ReaderDirection
    public var fixedLayout: Bool

    public init(openID: Int, toc: [ReaderTocItem], sectionCount: Int, direction: ReaderDirection, fixedLayout: Bool) {
        self.openID = openID
        self.toc = toc
        self.sectionCount = sectionCount
        self.direction = direction
        self.fixedLayout = fixedLayout
    }
}

public struct ReaderSectionProgress: Codable, Hashable, Sendable {
    public var index: Int
    public var count: Int

    public init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }
}

public struct ReaderRelocatedPayload: Codable, Hashable, Sendable {
    public var cfi: String
    /// 0…1 through the whole book.
    public var fraction: Double
    public var section: ReaderSectionProgress
    public var tocLabel: String?
    public var pageLabel: String?
    /// Pages remaining in the current section; nil in scrolled flow or fixed layout.
    public var pagesLeftInSection: Int?
    public var atStart: Bool
    public var atEnd: Bool

    public init(cfi: String, fraction: Double, section: ReaderSectionProgress, tocLabel: String?, pageLabel: String?,
                pagesLeftInSection: Int?, atStart: Bool, atEnd: Bool) {
        self.cfi = cfi
        self.fraction = fraction
        self.section = section
        self.tocLabel = tocLabel
        self.pageLabel = pageLabel
        self.pagesLeftInSection = pagesLeftInSection
        self.atStart = atStart
        self.atEnd = atEnd
    }
}

public struct ReaderSelectionChangedPayload: Codable, Hashable, Sendable {
    public var cfi: String
    public var text: String
    public var label: String?
    public var fraction: Double?
    public var rect: ReaderRect

    public init(cfi: String, text: String, label: String?, fraction: Double?, rect: ReaderRect) {
        self.cfi = cfi
        self.text = text
        self.label = label
        self.fraction = fraction
        self.rect = rect
    }
}

public struct ReaderAnnotationActivatedPayload: Codable, Hashable, Sendable {
    public var highlightIDs: [String]
    public var markerIDs: [String]
    public var rect: ReaderRect

    public init(highlightIDs: [String], markerIDs: [String], rect: ReaderRect) {
        self.highlightIDs = highlightIDs
        self.markerIDs = markerIDs
        self.rect = rect
    }
}

public struct ReaderLinkActivatedPayload: Codable, Hashable, Sendable {
    public var href: String
    public var external: Bool

    public init(href: String, external: Bool) {
        self.href = href
        self.external = external
    }
}

public struct ReaderSearchExcerpt: Codable, Hashable, Sendable {
    public var pre: String
    public var match: String
    public var post: String

    public init(pre: String, match: String, post: String) {
        self.pre = pre
        self.match = match
        self.post = post
    }
}

public struct ReaderSearchItem: Codable, Hashable, Sendable {
    public var cfi: String
    public var label: String?
    public var excerpt: ReaderSearchExcerpt

    public init(cfi: String, label: String?, excerpt: ReaderSearchExcerpt) {
        self.cfi = cfi
        self.label = label
        self.excerpt = excerpt
    }
}

public struct ReaderSearchResultsPayload: Codable, Hashable, Sendable {
    public var query: String
    public var items: [ReaderSearchItem]
    /// 0…1 through the book; batches may carry no items, only progress.
    public var progress: Double
    public var done: Bool

    public init(query: String, items: [ReaderSearchItem], progress: Double, done: Bool) {
        self.query = query
        self.items = items
        self.progress = progress
        self.done = done
    }
}

public struct ReaderErrorPayload: Codable, Hashable, Sendable {
    public var message: String
    /// The command or area that failed, when known.
    public var context: String?
    /// The `openID` of the `open` this failure belongs to (nil for anything else).
    public var openID: Int?

    public init(message: String, context: String?, openID: Int? = nil) {
        self.message = message
        self.context = context
        self.openID = openID
    }
}
