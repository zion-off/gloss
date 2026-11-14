import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossReaderBridge

@Suite("contents visibility")
struct ContentsVisibilityTests {
    /// Three chapters, the second with two nested parts.
    let nodes: [ContentsNode] = [
        ContentsNode(id: "0", label: "one", target: Locator(scheme: LocatorScheme("href"), value: "c1")),
        ContentsNode(id: "1", label: "two", target: Locator(scheme: LocatorScheme("href"), value: "c2"), children: [
            ContentsNode(id: "1.0", label: "part a", target: Locator(scheme: LocatorScheme("href"), value: "c2a")),
            ContentsNode(id: "1.1", label: "part b", target: Locator(scheme: LocatorScheme("href"), value: "c2b")),
        ]),
        ContentsNode(id: "2", label: "three", target: Locator(scheme: LocatorScheme("href"), value: "c3")),
    ]

    func location(_ href: String?) -> ReaderLocation {
        ReaderLocation(locator: Locator(scheme: LocatorScheme("cfi"), value: "x"), progression: 0.5, label: nil, progressText: "",
                       contentsTarget: href.map { Locator(scheme: LocatorScheme("href"), value: $0) })
    }

    @Test("the current entry is the row whose target the position names, nested or not")
    func currentRow() {
        #expect(ContentsVisibility.currentRow(in: nodes, at: location("c2b")) == "1.1")
        #expect(ContentsVisibility.currentRow(in: nodes, at: location("c1")) == "0")
        #expect(ContentsVisibility.currentRow(in: nodes, at: location("missing")) == nil)
        #expect(ContentsVisibility.currentRow(in: nodes, at: nil) == nil)
        #expect(ContentsVisibility.currentRow(in: [], at: location("c1")) == nil)
    }

    @Test("an entry that appears twice resolves to the first row, like the pages-left caption")
    func duplicateEntries() {
        let twice = nodes + [ContentsNode(id: "3", label: "two again", target: Locator(scheme: LocatorScheme("href"), value: "c2"))]
        #expect(ContentsVisibility.currentRow(in: twice, at: location("c2")) == "1")
    }

    @Test("scroll only when the entry really changed, not on a same-entry relocation")
    func scrolling() {
        #expect(ContentsVisibility.shouldScroll(previous: nil, current: "1.1"))
        #expect(ContentsVisibility.shouldScroll(previous: "0", current: "1.1"))
        #expect(!ContentsVisibility.shouldScroll(previous: "1.1", current: "1.1"))  // a page turn inside it
        #expect(!ContentsVisibility.shouldScroll(previous: "1.1", current: nil))  // the position lost its entry
    }

    @Test("the selection follows the chapter from the book or the contents, never from a highlight or page")
    func selectionFollows() {
        let highlight = HighlightID(GlossID(high: 9, low: 1)), page = PageID(GlossID(high: 9, low: 2))
        let partB = location("c2b")
        #expect(ContentsVisibility.followedSelection(.book, in: nodes, at: partB) == .contents("1.1"))
        #expect(ContentsVisibility.followedSelection(.contents("0"), in: nodes, at: partB) == .contents("1.1"))
        #expect(ContentsVisibility.followedSelection(.contents("1.1"), in: nodes, at: partB) == nil)
        #expect(ContentsVisibility.followedSelection(.highlight(highlight), in: nodes, at: partB) == nil)
        #expect(ContentsVisibility.followedSelection(.page(page), in: nodes, at: partB) == nil)
        #expect(ContentsVisibility.followedSelection(.book, in: nodes, at: location("missing")) == nil)
    }

    @Test("a clicked entry that still covers the position keeps the selection")
    func clickedEntryStays() {
        // "two" clicked, landing where its "part b" is: the chapter the user picked stays selected.
        #expect(ContentsVisibility.followedSelection(.contents("1"), in: nodes, at: location("c2b")) == nil)
        // The second listing of the same place clicked: it names the position too.
        let twice = nodes + [ContentsNode(id: "3", label: "two again", target: Locator(scheme: LocatorScheme("href"), value: "c2"))]
        #expect(ContentsVisibility.followedSelection(.contents("3"), in: twice, at: location("c2")) == nil)
        // Reading on into the next chapter moves it.
        #expect(ContentsVisibility.followedSelection(.contents("1"), in: nodes, at: location("c3")) == .contents("2"))
    }
}
