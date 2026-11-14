import Foundation
import Testing
import GlossCore
import GlossPDF
import GlossReaderBridge
@testable import GlossReaderPDFSupport

@Suite("pdf reading")
struct PDFReadingTests {
    let h1 = HighlightID(GlossID(high: 1, low: 1))
    let h2 = HighlightID(GlossID(high: 1, low: 2))
    let m1 = LinkTargetID(GlossID(high: 2, low: 1))

    func passage(_ spans: [PDFPassageLocator.PageSpan]) -> Locator { PDFPassageLocator(pages: spans).locator }

    @Test("targets: pages and passages; other engines' and malformed locators are refused")
    func targets() throws {
        #expect(try PDFReaderTarget(Locator(scheme: PDFLocators.pageScheme, value: "4")) == .page(4))
        let span = PDFPassageLocator.PageSpan(page: 7, ranges: [[3, 5]], rects: [[10, 20, 30, 12]])
        let target = try PDFReaderTarget(passage([span]))
        #expect(target.pageIndex == 7)
        for bad in [Locator(scheme: PDFLocators.pageScheme, value: "-1"), Locator(scheme: PDFLocators.pageScheme, value: "x"),
                    Locator(scheme: PDFLocators.passageScheme, value: "{}"), passage([]),
                    Locator(scheme: LocatorScheme("epubcfi"), value: "epubcfi(/6/2)")] {
            #expect(throws: ReaderDrivingError.self) { try PDFReaderTarget(bad) }
        }
    }

    @Test("positions: page locators, progression from first to last page, labels and progress text")
    func positions() {
        let first = PDFReaderPositions.location(page: 0, pageCount: 120)
        #expect(first.locator == Locator(scheme: PDFLocators.pageScheme, value: "0"))
        #expect(first.progression == 0 && first.atStart && !first.atEnd)
        #expect(first.label == "page 1" && first.progressText == "page 1 of 120")
        let last = PDFReaderPositions.location(page: 119, pageCount: 120)
        #expect(last.progression == 1 && last.atEnd && !last.atStart)
        #expect(PDFReaderPositions.location(page: 2, pageCount: 120, pageLabel: "xii").label == "page xii")
        #expect(PDFReaderPositions.location(page: 2, pageCount: 120, pageLabel: "  ").label == "page 3")
        // The outline entry being read: the last one starting on or before the page.
        let page = { PDFReaderPositions.locator(page: $0) }
        let toc = [ReaderTocEntry(label: "one", target: page(2)),
                   ReaderTocEntry(label: "two", target: page(10), children: [ReaderTocEntry(label: "two.a", target: page(14))]),
                   ReaderTocEntry(label: "three", target: page(30))]
        #expect(PDFReaderPositions.location(page: 15, pageCount: 120, toc: toc).contentsTarget == page(14))
        #expect(PDFReaderPositions.location(page: 10, pageCount: 120, toc: toc).contentsTarget == page(10))
        #expect(PDFReaderPositions.location(page: 1, pageCount: 120, toc: toc).contentsTarget == nil)  // before the first
        #expect(PDFReaderPositions.location(page: 100, pageCount: 120, toc: toc).contentsTarget == page(30))
        #expect(PDFReaderPositions.location(page: 5, pageCount: 120).contentsTarget == nil)  // no outline
        // Out of range pages clamp; a one-page document is both start and end.
        #expect(PDFReaderPositions.location(page: 500, pageCount: 3).locator.value == "2")
        let single = PDFReaderPositions.location(page: 0, pageCount: 1)
        #expect(single.atStart && single.atEnd && single.progression == 0)
    }

    @Test("annotations group by page; a click hits what's under it, with slop")
    func layout() {
        let annotations = ReaderAnnotations(
            highlights: [
                .init(id: h1, locator: passage([.init(page: 2, ranges: [[0, 4]], rects: [[100, 200, 50, 10]]),
                                                .init(page: 3, ranges: [[0, 2]], rects: [[100, 700, 20, 10]])]), color: .pink),
                .init(id: h2, locator: Locator(scheme: LocatorScheme("epubcfi"), value: "epubcfi(/6/2)"), color: .blue),
            ],
            markers: [.init(id: m1, locator: passage([.init(page: 2, ranges: [[2, 6]], rects: [[120, 200, 60, 10], [1, 2, 3]])]))])
        let layout = PDFAnnotationLayout(annotations)
        #expect(layout.marks(on: 2).count == 2)
        #expect(layout.marks(on: 3).count == 1)
        #expect(layout.marks(on: 9).isEmpty)
        // The malformed rect is dropped, the good one kept.
        #expect(layout.marks(on: 2).last?.rects == [PDFPageRect(x: 120, y: 200, width: 60, height: 10)])

        let both = layout.hit(x: 130, y: 205, on: 2)
        #expect(both.highlights == [h1] && both.markers == [m1])
        let onlyMarker = layout.hit(x: 170, y: 205, on: 2)
        #expect(onlyMarker.highlights.isEmpty && onlyMarker.markers == [m1])
        #expect(layout.hit(x: 99, y: 199, on: 2).highlights == [h1])          // within the 2-point slop
        #expect(layout.hit(x: 90, y: 205, on: 2).highlights.isEmpty)
        #expect(layout.hit(x: 130, y: 205, on: 3).highlights.isEmpty)        // other page
    }

    @Test("a click on one page's marks reports what it hit and the rect to anchor a popover to")
    func markHit() {
        let marks = [
            PDFAnnotationLayout.Mark(kind: .highlight(h1, .yellow), rects: [PDFPageRect(x: 0, y: 0, width: 10, height: 10),
                                                                            PDFPageRect(x: 100, y: 200, width: 50, height: 10)]),
            PDFAnnotationLayout.Mark(kind: .marker(m1), rects: [PDFPageRect(x: 120, y: 200, width: 60, height: 10)]),
        ]
        let hit = PDFAnnotationLayout.hit(marks, x: 130, y: 205)
        #expect(hit?.highlights == [h1] && hit?.markers == [m1])
        // The anchor is the first mark's rect that was hit, not its first rect.
        #expect(hit?.rect == PDFPageRect(x: 100, y: 200, width: 50, height: 10))
        #expect(PDFAnnotationLayout.hit(marks, x: 170, y: 205)?.rect == PDFPageRect(x: 120, y: 200, width: 60, height: 10))
        #expect(PDFAnnotationLayout.hit(marks, x: 500, y: 500) == nil)
        #expect(PDFAnnotationLayout.hit([], x: 0, y: 0) == nil)
    }

    /// An outline node for the walk: children by index, a title and a page.
    final class Node {
        let label: String?
        let page: Int?
        var children: [Node]
        init(_ label: String?, page: Int?, _ children: [Node] = []) {
            self.label = label
            self.page = page
            self.children = children
        }
    }

    func toc(_ root: Node?, maxDepth: Int = 4, maxNodes: Int = 2000) -> [ReaderTocEntry] {
        PDFOutlineTOC.entries(root: root, maxDepth: maxDepth, maxNodes: maxNodes,
                              childCount: { $0.children.count }, child: { $1 < $0.children.count ? $0.children[$1] : nil },
                              label: \.label, page: \.page)
    }

    @Test("the outline becomes a nested table of contents of page locators")
    func outline() {
        let root = Node(nil, page: nil, [
            Node("part one", page: 0, [Node("chapter 1", page: 2), Node("chapter 2", page: 9)]),
            Node("  part two ", page: 20),
        ])
        let entries = toc(root)
        #expect(entries.map(\.label) == ["part one", "part two"])
        #expect(entries[0].target == PDFReaderPositions.locator(page: 0))
        #expect(entries[0].children.map(\.label) == ["chapter 1", "chapter 2"])
        #expect(entries[0].children[1].target == PDFReaderPositions.locator(page: 9))
        #expect(toc(nil).isEmpty)
    }

    @Test("outline entries with nowhere to go hand their children up instead of pointing at page 1")
    func outlineUnresolved() {
        let root = Node(nil, page: nil, [
            Node("broken link", page: nil, [Node("inner", page: 4)]),
            Node("", page: 6, [Node("under a blank title", page: 7)]),
            Node("negative", page: -1),
        ])
        #expect(toc(root).map(\.label) == ["inner", "under a blank title"])
    }

    @Test("a deep, wide or cyclic outline stops at the limits")
    func outlineBounded() {
        // Depth: only maxDepth levels come out.
        var deep = Node("level 5", page: 5)
        for level in (0..<5).reversed() { deep = Node("level \(level)", page: level, [deep]) }
        let shallow = toc(Node(nil, page: nil, [deep]), maxDepth: 2)
        #expect(shallow.count == 1 && shallow[0].children.count == 1 && shallow[0].children[0].children.isEmpty)

        // A cycle (a node that is its own child) ends at the node budget.
        let loop = Node("loop", page: 1)
        loop.children = [loop]
        let cyclic = toc(Node(nil, page: nil, [loop]), maxDepth: 1000, maxNodes: 50)
        #expect(cyclic.count == 1)

        // A node claiming billions of children is cut off by the budget, too.
        let wide = PDFOutlineTOC.entries(root: 0, maxNodes: 100, childCount: { $0 == 0 ? Int.max : 0 },
                                         child: { _, index in index + 1 }, label: { "page \($0)" }, page: { $0 })
        #expect(wide.count == 100)
    }

    @Test("a search hit's words are found on its own page, ignoring case and accents")
    func textMatch() {
        let page = "Le Café de Flore — the café where Camus wrote"
        #expect(PDFTextMatch.range(of: "cafe", in: page) == 3..<7)
        #expect(PDFTextMatch.range(of: "  camus ", in: page).map { (page as NSString).substring(with: NSRange(location: $0.lowerBound, length: $0.count)) } == "Camus")
        #expect(PDFTextMatch.range(of: "sartre", in: page) == nil)
        #expect(PDFTextMatch.range(of: "   ", in: page) == nil)
        #expect(PDFTextMatch.range(of: "x", in: "") == nil)
    }

    @Test("selections become passages; empty ones don't")
    func selections() throws {
        let selection = [
            PDFPageSelection(page: 5, ranges: [12..<20], rects: [PDFPageRect(x: 1, y: 2, width: 3, height: 4)], text: "the end of\n"),
            PDFPageSelection(page: 4, ranges: [100..<130], rects: [], text: "One must imagine"),
            PDFPageSelection(page: 6, ranges: [], rects: [], text: "nothing selected here"),
        ]
        let passage = try #require(PDFSelectionMapping.passage(from: selection, pageCount: 11))
        #expect(passage.quote == "One must imagine the end of")
        #expect(passage.label == "page 5–6")
        #expect(passage.progression == 0.4)
        let locator = try #require(PDFPassageLocator(locator: passage.locator))
        #expect(locator.pages.map(\.page) == [4, 5])
        #expect(locator.pages.first?.ranges == [[100, 30]])
        #expect(locator.pages.last?.rects == [[1, 2, 3, 4]])

        let labelled = PDFSelectionMapping.passage(from: [selection[1]], pageCount: 11) { $0 == 4 ? "iv" : nil }
        #expect(labelled?.label == "page iv")
        #expect(PDFSelectionMapping.passage(from: [], pageCount: 3) == nil)
        #expect(PDFSelectionMapping.passage(from: [PDFPageSelection(page: 0, ranges: [0..<2], rects: [], text: "  \n")], pageCount: 3) == nil)
    }
}

@Suite("pdf quote locators")
struct PDFQuoteResolverTests {
    @Test("quote markers become passage locators on their own occurrence, once; unfound ones drop out")
    func resolve() throws {
        // PDFKit breaks lines where the extractor put spaces, and the page has the words twice.
        let pageText = "the white whale\nand then the white\nwhale again"
        let anchor = QuoteAnchor(text: "the white whale", prefix: "and then", suffix: "again", occurrence: 1)
        let quote = PDFQuoteLocator(page: 2, quote: anchor).locator
        let missing = PDFQuoteLocator(page: 2, quote: QuoteAnchor(text: "a fish")).locator
        let cfi = Locator(scheme: LocatorScheme("epubcfi"), value: "x")
        var measured: [Range<Int>] = []
        var resolver = PDFQuoteResolver()
        let annotations = ReaderAnnotations(markers: [
            .init(id: LinkTargetID(GlossID(high: 1, low: 1)), locator: quote),
            .init(id: LinkTargetID(GlossID(high: 1, low: 2)), locator: missing),
            .init(id: LinkTargetID(GlossID(high: 1, low: 3)), locator: cfi),
        ])
        let rects = { (_: Int, range: Range<Int>) -> [PDFPageRect] in
            measured.append(range)
            return [PDFPageRect(x: 1, y: 2, width: 3, height: 4)]
        }
        let resolved = resolver.resolve(annotations, pageText: { $0 == 2 ? pageText : nil }, lineRects: rects)
        #expect(resolved.markers.count == 2)
        let passage = try #require(PDFPassageLocator(locator: resolved.markers[0].locator))
        #expect(passage.pages == [.init(page: 2, ranges: [[25, 15]], rects: [[1, 2, 3, 4]])])
        #expect(resolved.markers[1].locator == cfi)
        // Cached: drawing again measures nothing new.
        _ = resolver.resolve(annotations, pageText: { $0 == 2 ? pageText : nil }, lineRects: rects)
        #expect(measured == [25..<40])
        #expect(PDFQuoteResolver.fallback(for: missing) == PDFReaderPositions.locator(page: 2))
        #expect(PDFQuoteResolver.fallback(for: cfi) == nil)
    }
}
