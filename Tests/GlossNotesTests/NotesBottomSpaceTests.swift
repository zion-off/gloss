import Testing
@testable import GlossNotes

@Suite("notes bottom space")
struct NotesBottomSpaceTests {
    @Test("the space is a little under half the pane")
    func height() {
        #expect(NotesBottomSpace.height(visibleHeight: 800) == 320)
        #expect(NotesBottomSpace.height(visibleHeight: 0) == 0)
    }

    @Test("a long page gets the space under its last line; a short one doesn't scroll")
    func documentHeight() {
        #expect(NotesBottomSpace.documentHeight(natural: 2000, visibleHeight: 800, minimum: 800) == 2320)
        #expect(NotesBottomSpace.documentHeight(natural: 300, visibleHeight: 800, minimum: 800) == 800)
        // Text that almost fills the pane: the space makes it scroll just enough.
        #expect(NotesBottomSpace.documentHeight(natural: 700, visibleHeight: 800, minimum: 800) == 1020)
    }

    @Test("typing keeps the space below the caret in view")
    func typingTarget() {
        let target = NotesBottomSpace.typingTarget(minY: 1000, maxY: 1020, visibleHeight: 800, documentHeight: 2320)
        #expect(target.minY == 1000 && target.maxY == 1340)
    }

    @Test("the typing target stops at the document's end and never outgrows the pane")
    func typingTargetClamps() {
        let atEnd = NotesBottomSpace.typingTarget(minY: 1980, maxY: 2000, visibleHeight: 800, documentHeight: 2100)
        #expect(atEnd.maxY == 2100)
        let tallLine = NotesBottomSpace.typingTarget(minY: 0, maxY: 700, visibleHeight: 800, documentHeight: 5000)
        #expect(tallLine.maxY == 800)  // the caret's top stays in view
        let taller = NotesBottomSpace.typingTarget(minY: 0, maxY: 900, visibleHeight: 800, documentHeight: 5000)
        #expect(taller.maxY == 900)  // never less than the rect itself
    }
}
