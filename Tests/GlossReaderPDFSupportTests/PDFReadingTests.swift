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
