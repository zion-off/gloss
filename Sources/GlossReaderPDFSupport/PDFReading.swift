import Foundation
import GlossCore
import GlossPDF
import GlossReaderBridge

// What the PDFKit engine does that needs no PDFKit: where it can go, what it reports as the
// position, which annotations sit on which page and what a click hits, and how a selection
// becomes a passage. The Mac engine only measures (PDFKit) and draws.

/// A rectangle in PDF page space (points, bottom-left origin).
public struct PDFPageRect: Hashable, Sendable {
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

    /// From a locator's `[x, y, width, height]`; nil for anything else (no negative sizes).
    public init?(_ values: [Double]) {
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] >= 0, values[3] >= 0 else { return nil }
        self.init(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    public var values: [Double] { [x, y, width, height] }

    /// Whether a point is inside, with `slop` points of tolerance on every side.
    public func contains(x px: Double, y py: Double, slop: Double = 0) -> Bool {
        px >= x - slop && px <= x + width + slop && py >= y - slop && py <= y + height + slop
    }
}

/// Where the PDF reader can go.
public enum PDFReaderTarget: Hashable, Sendable {
    /// A page (positions and search hits).
    case page(Int)
    /// A passage (highlights, note links).
    case passage(PDFPassageLocator)

    /// The target for a locator; throws `unsupportedLocator` for other engines' locators and
    /// malformed ones.
    public init(_ locator: Locator) throws {
        switch locator.scheme {
        case PDFLocators.pageScheme:
            guard let page = Int(locator.value), page >= 0 else { throw ReaderDrivingError.unsupportedLocator(locator.scheme) }
            self = .page(page)
        case PDFLocators.passageScheme:
            guard let passage = PDFPassageLocator(locator: locator), !passage.pages.isEmpty, passage.pages.allSatisfy({ $0.page >= 0 }) else {
                throw ReaderDrivingError.unsupportedLocator(locator.scheme)
            }
            self = .passage(passage)
        default:
            throw ReaderDrivingError.unsupportedLocator(locator.scheme)
        }
    }

    public var pageIndex: Int {
        switch self {
        case .page(let page): page
        case .passage(let passage): passage.firstPage
        }
    }
}

public enum PDFReaderPositions {
    /// The position locator for a page (shared with search chunks: `pdf-page`, zero-based).
    public static func locator(page: Int) -> Locator {
        Locator(scheme: PDFLocators.pageScheme, value: String(page))
    }

    /// 0 on the first page, 1 on the last.
    public static func progression(page: Int, pageCount: Int) -> Double {
        guard pageCount > 1 else { return 0 }
        return min(max(Double(page) / Double(pageCount - 1), 0), 1)
    }

    /// "page 3", or the PDF's own label when it has one that isn't just the number ("page xii").
    public static func label(page: Int, pageLabel: String?) -> String {
        let label = pageLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "page \(label.isEmpty ? String(page + 1) : label)"
    }

    /// Where the reader is, for `ReaderEngineEvent.relocated`.
    public static func location(page: Int, pageCount: Int, pageLabel: String? = nil) -> ReaderLocation {
        let clamped = min(max(page, 0), max(pageCount - 1, 0))
        let text = pageCount > 0 ? "page \(clamped + 1) of \(pageCount)" : ""
        return ReaderLocation(locator: locator(page: clamped), progression: progression(page: clamped, pageCount: pageCount),
                              label: label(page: clamped, pageLabel: pageLabel), progressText: text,
                              atStart: clamped == 0, atEnd: clamped >= pageCount - 1)
    }
}

/// Highlights and note markers, grouped by the page they sit on, and what a click hits.
public struct PDFAnnotationLayout: Hashable, Sendable {
    public struct Mark: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case highlight(HighlightID, HighlightColor)
            case marker(LinkTargetID)
        }

        public var kind: Kind
        public var rects: [PDFPageRect]
    }

    public private(set) var pages: [Int: [Mark]] = [:]

    /// Only PDF passage locators count; other engines' annotations are skipped.
    public init(_ annotations: ReaderAnnotations) {
        for mark in annotations.highlights { add(.highlight(mark.id, mark.color), at: mark.locator) }
        for mark in annotations.markers { add(.marker(mark.id), at: mark.locator) }
    }

    private mutating func add(_ kind: Mark.Kind, at locator: Locator) {
        guard let passage = PDFPassageLocator(locator: locator) else { return }
        for span in passage.pages {
            let rects = span.rects.compactMap(PDFPageRect.init)
            guard !rects.isEmpty else { continue }
            pages[span.page, default: []].append(Mark(kind: kind, rects: rects))
        }
    }

    public func marks(on page: Int) -> [Mark] { pages[page] ?? [] }

    /// The highlights and markers under a point on a page (page space).
    public func hit(x: Double, y: Double, on page: Int, slop: Double = 2) -> (highlights: [HighlightID], markers: [LinkTargetID]) {
        let hit = Self.hit(marks(on: page), x: x, y: y, slop: slop)
        return (hit?.highlights ?? [], hit?.markers ?? [])
    }

    /// What a click at a point (page space) hits among one page's marks, or nil for nothing.
    public static func hit(_ marks: [Mark], x: Double, y: Double, slop: Double = 2) -> Hit? {
        var hit = Hit(highlights: [], markers: [], rect: PDFPageRect(x: x, y: y, width: 1, height: 1))
        var anchored = false
        for mark in marks {
            guard let rect = mark.rects.first(where: { $0.contains(x: x, y: y, slop: slop) }) else { continue }
            if !anchored { hit.rect = rect; anchored = true }
            switch mark.kind {
            case .highlight(let id, _): if !hit.highlights.contains(id) { hit.highlights.append(id) }
            case .marker(let id): if !hit.markers.contains(id) { hit.markers.append(id) }
            }
        }
        return anchored ? hit : nil
    }

    /// A click on marks: everything under it, and the first hit rect (where a popover anchors).
    public struct Hit: Hashable, Sendable {
        public var highlights: [HighlightID]
        public var markers: [LinkTargetID]
        public var rect: PDFPageRect
    }
}

/// A PDF's outline as the reader's table of contents, walked through accessors so it runs
/// without PDFKit. A PDF's outline comes from the file, so it may be huge, deep or even cyclic:
/// the walk is bounded in depth and in the number of nodes it visits.
public enum PDFOutlineTOC {
    public static func entries<Node>(root: Node?, maxDepth: Int = 4, maxNodes: Int = 2000,
                                     childCount: (Node) -> Int, child: (Node, Int) -> Node?,
                                     label: (Node) -> String?, page: (Node) -> Int?) -> [ReaderTocEntry] {
        guard let root else { return [] }
        var budget = maxNodes
        func walk(_ node: Node, depth: Int) -> [ReaderTocEntry] {
            guard depth < maxDepth else { return [] }
            var result: [ReaderTocEntry] = []
            for index in 0..<max(childCount(node), 0) {
                guard budget > 0 else { break }
                budget -= 1
                guard let item = child(node, index) else { continue }
                let children = walk(item, depth: depth + 1)
                let title = label(item)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !title.isEmpty, let target = page(item), target >= 0 {
                    result.append(ReaderTocEntry(label: title, target: PDFReaderPositions.locator(page: target), children: children))
                } else {
                    // Nowhere to go (no title, or a destination PDFKit couldn't resolve): its
                    // children move up instead of all pointing at page 1.
                    result.append(contentsOf: children)
                }
            }
            return result
        }
        return walk(root, depth: 0)
    }
}

/// Finding a search hit's words on one page, so a hit lands on its own occurrence.
public enum PDFTextMatch {
    /// The UTF-16 range of `text` in `pageText` (case- and diacritic-insensitive), or nil.
    public static func range(of text: String, in pageText: String) -> Range<Int>? {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let found = (pageText as NSString).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        guard found.location != NSNotFound, found.length > 0 else { return nil }
        return found.location..<(found.location + found.length)
    }
}

/// A PDFKit selection, measured: what it covers on each page.
public struct PDFPageSelection: Hashable, Sendable {
    public var page: Int
    /// `(location, length)` UTF-16 ranges into `PDFPage.string`.
    public var ranges: [Range<Int>]
    public var rects: [PDFPageRect]
    public var text: String

    public init(page: Int, ranges: [Range<Int>], rects: [PDFPageRect], text: String) {
        self.page = page
        self.ranges = ranges
        self.rects = rects
        self.text = text
    }
}

public enum PDFSelectionMapping {
    /// The passage for a selection; nil when it covers no text.
    public static func passage(from selection: [PDFPageSelection], pageCount: Int,
                               pageLabel: (Int) -> String? = { _ in nil }) -> Passage? {
        let pages = selection
            .filter { !$0.ranges.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.page < $1.page }
        guard let first = pages.first, let last = pages.last else { return nil }
        let locator = PDFPassageLocator(pages: pages.map { page in
            PDFPassageLocator.PageSpan(page: page.page,
                                       ranges: page.ranges.map { [$0.lowerBound, $0.count] },
                                       rects: page.rects.map(\.values))
        }).locator
        let firstLabel = PDFReaderPositions.label(page: first.page, pageLabel: pageLabel(first.page))
        let label = first.page == last.page
            ? firstLabel
            : firstLabel + "–" + (pageLabel(last.page).flatMap { $0.isEmpty ? nil : $0 } ?? String(last.page + 1))
        return Passage(locator: locator, quote: pages.map(\.text).joined(separator: " "), label: label,
                       progression: PDFReaderPositions.progression(page: first.page, pageCount: pageCount))
    }
}
