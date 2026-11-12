import Foundation
import Testing
import GlossCore
import GlossPDF

@Suite("PDF passage locators")
struct PDFLocatorTests {
    @Test("locator schemes are named correctly")
    func schemes() {
        #expect(PDFLocators.pageScheme.rawValue == "pdf-page")
        #expect(PDFLocators.passageScheme.rawValue == "pdf")
    }

    @Test("round-trips through the opaque locator with sorted compact JSON")
    func roundTrip() throws {
        let first = PDFPassageLocator.PageSpan(page: 2, ranges: [[10, 5]], rects: [[1, 2, 3, 4]])
        let second = PDFPassageLocator.PageSpan(page: 3, ranges: [[0, 2], [7, 3]], rects: [])
        let passage = PDFPassageLocator(pages: [first, second])

        let locator = passage.locator
        #expect(locator.scheme == PDFLocators.passageScheme)
        // Sorted keys: "pages" sorts before "v".
        #expect(locator.value.hasPrefix("{\"pages\":[{"))
        #expect(!locator.value.contains("\n"))

        let decoded = try #require(PDFPassageLocator(locator: locator))
        #expect(decoded == passage)
        #expect(decoded.v == 1)
        #expect(decoded.firstPage == 2)
        #expect(decoded.label == "pages 3–4")
    }

    @Test("labels single pages without a plural")
    func singlePageLabel() {
        let passage = PDFPassageLocator(pages: [
            PDFPassageLocator.PageSpan(page: 2, ranges: [[10, 5]], rects: []),
        ])
        #expect(passage.label == "page 3")
        #expect(passage.firstPage == 2)
    }

    @Test("empty locators label empty and start at page 0")
    func emptyLabel() {
        let passage = PDFPassageLocator(pages: [])
        #expect(passage.label == "")
        #expect(passage.firstPage == 0)
    }

    @Test("rejects foreign schemes and bad JSON")
    func rejectsForeign() {
        #expect(PDFPassageLocator(locator: Locator(scheme: PDFLocators.pageScheme, value: "2")) == nil)
        #expect(PDFPassageLocator(locator: Locator(scheme: LocatorScheme("epubcfi"), value: "/6/4")) == nil)
        #expect(PDFPassageLocator(locator: Locator(scheme: PDFLocators.passageScheme, value: "{not json")) == nil)
        #expect(PDFPassageLocator(locator: Locator(scheme: PDFLocators.passageScheme, value: "{\"v\":1}")) == nil)
    }
}
