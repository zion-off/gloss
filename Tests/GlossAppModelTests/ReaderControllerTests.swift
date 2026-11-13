import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossMarkdown
import GlossNotes
import GlossReaderBridge
import GlossTestSupport

/// Records what the controller asks the engine to do.
@MainActor
final class FakeDriver: ReaderDriving {
    enum Call: Equatable {
        case open(DocumentID, Locator?)
        case close
        case go(Locator, flash: Bool)
        case turn(forward: Bool)
        case show(ReaderAnnotations)
        case clearSelection
        case reveal(Locator?, String)
    }

    var calls: [Call] = []
    var openIDs: [Int] = []
    var failGo = false

    /// The id the engine would echo in `.opened` for the latest open.
    var lastOpenID: Int { openIDs.last ?? 0 }

    func open(_ document: Document, at position: Locator?, openID: Int) async throws {
        calls.append(.open(document.id, position))
        openIDs.append(openID)
    }
    func close() async throws { calls.append(.close) }
    func go(to locator: Locator, flash: Bool) async throws {
        if failGo { throw ReaderDrivingError.unsupportedLocator(locator.scheme) }
        calls.append(.go(locator, flash: flash))
    }
    func turnPage(forward: Bool) async throws { calls.append(.turn(forward: forward)) }
    func show(_ annotations: ReaderAnnotations) async throws { calls.append(.show(annotations)) }
    func clearSelection() async throws { calls.append(.clearSelection) }
    func reveal(searchHit locator: Locator?, text: String) async throws { calls.append(.reveal(locator, text)) }

    var lastAnnotations: ReaderAnnotations? {
        calls.reversed().compactMap { if case .show(let a) = $0 { a } else { nil } }.first
    }

    var opens: [DocumentID] { calls.compactMap { if case .open(let id, _) = $0 { id } else { nil } } }
}

extension ReaderController {
    /// Opens a book the way the real engine answers: ready (once), open, then the matching
    /// `.opened`.
    func openShowing(_ document: Document, at locator: Locator? = nil, on driver: FakeDriver, toc: [ReaderTocEntry] = []) async {
        if !isReady { await handle(.ready) }
        await open(document, at: locator)
        await handle(.opened(toc: toc, openID: driver.lastOpenID))
    }
}

@MainActor
struct ReaderControllerTests {
    let anchor = ReaderRect(x: 10, y: 20, width: 100, height: 18)

    func location(_ value: String, _ progression: Double) -> ReaderLocation {
        ReaderLocation(locator: Locator(scheme: FakeFormat.scheme, value: value), progression: progression,
                       label: "chapter 2", progressText: "3 pages left in chapter 2")
    }

    @Test("opening waits for the engine, then opens at the saved position and draws annotations")
    func openFlow() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book()
        try await lib.services.library.savePosition(Locator(scheme: FakeFormat.scheme, value: "saved"), progression: 0.4, label: nil, of: book.id)
        _ = try await lib.services.highlights.add(lib.passage("q", at: "h1"), color: .green, in: book.id)
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.open(book)
        #expect(driver.calls.isEmpty)  // not ready yet
        await controller.handle(.ready)
        #expect(driver.calls == [.open(book.id, Locator(scheme: FakeFormat.scheme, value: "saved"))])
        await controller.handle(.opened(toc: [ReaderTocEntry(label: "one", target: Locator(scheme: FakeFormat.scheme, value: "t1"))],
                                        openID: driver.lastOpenID))
        #expect(controller.isShowingBook)
        #expect(controller.toc.map(\.label) == ["one"])
        #expect(driver.lastAnnotations?.highlights.map(\.color) == [.green])
        #expect(try await lib.services.library.document(book.id)?.lastOpenedAt != nil)
    }

    @Test("opening at a passage goes there and flashes it after the book loads")
    func openAtPassage() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book()
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.handle(.ready)
        let passage = Locator(scheme: FakeFormat.scheme, value: "p")
        await controller.open(book, at: passage)
        await controller.handle(.opened(toc: [], openID: driver.lastOpenID))
        #expect(driver.calls.first == .open(book.id, passage))
        #expect(driver.calls.last == .go(passage, flash: true))
        // Already open: going to another passage doesn't reopen the book.
        let other = Locator(scheme: FakeFormat.scheme, value: "q")
        await controller.open(book, at: other)
        #expect(driver.calls.last == .go(other, flash: true))
        #expect(driver.calls.filter { if case .open = $0 { true } else { false } }.count == 1)
    }

    @Test("relocations update the location and the saved position, newest last")
    func positions() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book()
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.openShowing(book, on: driver)
        for (index, progression) in [0.1, 0.2, 0.3, 0.45].enumerated() {
            await controller.handle(.relocated(location("l\(index)", progression)))
        }
        await controller.flushPosition()
        #expect(controller.location?.progressText == "3 pages left in chapter 2")
        let saved = try await lib.services.library.position(of: book.id)
        #expect(saved?.locator.value == "l3")
        #expect(saved?.progression == 0.45)
        #expect(saved?.label == "chapter 2")
    }

    @Test("selections become book selections; highlighting clears them and redraws")
    func selection() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book()
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.openShowing(book, on: driver)
        let passage = lib.passage("a passage", at: "sel")
        await controller.handle(.selectionChanged(passage, anchor: anchor))
        #expect(controller.selection == BookSelection(documentID: book.id, passage: passage))
        #expect(controller.selectionAnchor == anchor)
        let highlight = try #require(try await controller.highlightSelection(.blue))
        #expect(controller.selection == nil)
        #expect(driver.calls.contains(.clearSelection))
        #expect(driver.lastAnnotations?.highlights.map(\.id) == [highlight.id])
        await controller.handle(.selectionChanged(passage, anchor: anchor))
        await controller.handle(.selectionCleared)
        #expect(controller.selection == nil)
    }

    @Test("clicking a highlight focuses it; recolour and delete redraw, and undo restores")
    func highlightClicks() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book()
        let highlight = try await lib.services.highlights.add(lib.passage("q", at: "h"), in: book.id)
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.openShowing(book, on: driver)
        await controller.handle(.annotationActivated(highlights: [highlight.id], markers: [], anchor: anchor))
        #expect(controller.highlightFocus?.highlight.id == highlight.id)
        try await controller.recolor(highlight.id, to: .purple)
        #expect(controller.highlightFocus?.highlight.color == .purple)
        #expect(driver.lastAnnotations?.highlights.first?.color == .purple)
        let deleted = try #require(try await controller.deleteHighlight(highlight.id))
        #expect(controller.highlightFocus == nil)
        #expect(driver.lastAnnotations?.highlights.isEmpty == true)
        try await controller.restoreHighlight(deleted)
        #expect(driver.lastAnnotations?.highlights.count == 1)
    }

    @Test("engine errors surface as friendly messages; web links go out")
    func errorsAndLinks() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book()
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        driver.failGo = true
        var opened: [URL] = []
        controller.openExternal = { opened.append($0) }
        controller.attach(driver)
        await controller.openShowing(book, on: driver)
        await controller.go(to: Locator(scheme: LocatorScheme("weird"), value: "x"))
        #expect(controller.errorMessage == "the reader can't go there")
        await controller.handle(.externalLink(URL(string: "https://example.com")!))
        #expect(opened == [URL(string: "https://example.com")!])
        // Only web and mail links leave the book: no files, no app launches.
        for link in ["file:///Applications/Calculator.app", "x-apple.systempreferences:", "gloss://book/x", "javascript:alert(1)"] {
            await controller.handle(.externalLink(URL(string: link)!))
        }
        await controller.handle(.externalLink(URL(string: "MAILTO:camus@example.com")!))
        #expect(opened == [URL(string: "https://example.com")!, URL(string: "MAILTO:camus@example.com")!])
        await controller.handle(.failed("open: 404"))
        #expect(controller.errorMessage == "open: 404")
    }

    // MARK: Review 3: events carry no book identity

    @Test("events from the previous book never land on the next one")
    func lateEventsFromThePreviousBook() async throws {
        let lib = TestLibrary()
        let (a, _) = try await lib.book("A")
        let (b, _) = try await lib.book("B")
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.openShowing(a, on: driver)
        await controller.handle(.relocated(location("pos-in-a", 0.2)))
        let firstOpen = driver.lastOpenID

        await controller.open(b)
        #expect(!controller.isShowingBook)
        // foliate's debounced relocate and selection for A arrive after B was asked for.
        await controller.handle(.relocated(location("late-from-a", 0.9)))
        await controller.handle(.selectionChanged(lib.passage("a's words", at: "a-sel"), anchor: anchor))
        await controller.handle(.annotationActivated(highlights: [], markers: [], anchor: anchor))
        // So does a stale reply to A's open.
        await controller.handle(.opened(toc: [], openID: firstOpen))
        await controller.flushPosition()
        #expect(controller.selection == nil && controller.selectionAnchor == nil)
        #expect(controller.location == nil)
        #expect(!controller.isShowingBook)
        #expect(try await lib.services.library.position(of: b.id) == nil)
        #expect(try await lib.services.library.position(of: a.id)?.locator.value == "pos-in-a")

        // B's own events count once its open is answered.
        await controller.handle(.opened(toc: [], openID: driver.lastOpenID))
        await controller.handle(.relocated(location("b-1", 0.1)))
        await controller.flushPosition()
        #expect(try await lib.services.library.position(of: b.id)?.locator.value == "b-1")
        #expect(driver.opens == [a.id, b.id])  // the engine reopens in place
    }

    @Test("a reply to an open that a newer one replaced is ignored")
    func replacedOpen() async throws {
        let lib = TestLibrary()
        let (a, _) = try await lib.book("A")
        let (b, _) = try await lib.book("B")
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.handle(.ready)
        await controller.open(a)
        let openA = driver.lastOpenID
        await controller.open(b)
        #expect(driver.lastOpenID != openA)
        await controller.handle(.opened(toc: [ReaderTocEntry(label: "a's toc", target: Locator(scheme: FakeFormat.scheme, value: "x"))],
                                        openID: openA))
        #expect(!controller.isShowingBook && controller.toc.isEmpty)
        await controller.handle(.opened(toc: [], openID: driver.lastOpenID))
        #expect(controller.isShowingBook && controller.document?.id == b.id)
    }

    @Test("an open overtaken while it read the saved position gives way")
    func overtakenOpen() async throws {
        let lib = TestLibrary()
        let (a, _) = try await lib.book("A")
        let (b, _) = try await lib.book("B")
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.handle(.ready)
        let first = Task { await controller.open(a) }
        let second = Task { await controller.open(b) }
        await first.value
        await second.value
        #expect(driver.opens == [b.id])
        #expect(controller.document?.id == b.id)
    }

    @Test("closing tells the engine and drops what it still reports")
    func closing() async throws {
        let lib = TestLibrary()
        let (a, _) = try await lib.book("A")
        let (b, _) = try await lib.book("B")
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.openShowing(a, on: driver)
        await controller.close()
        #expect(driver.calls.last == .close)
        await controller.handle(.relocated(location("after-close", 0.5)))
        await controller.flushPosition()
        #expect(controller.location == nil)
        #expect(try await lib.services.library.position(of: a.id) == nil)
        // The same engine opens the next book.
        await controller.openShowing(b, on: driver)
        #expect(controller.isShowingBook && controller.document?.id == b.id)
    }

    @Test("passages asked for while the book opens land once it has; commands wait for it")
    func commandsWhileOpening() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book()
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.handle(.ready)
        await controller.open(book)
        let passage = Locator(scheme: FakeFormat.scheme, value: "p")
        await controller.go(to: passage)
        await controller.turnPage(forward: true)
        await controller.reveal(searchHit: passage, text: "t")
        await controller.refreshAnnotations()
        #expect(driver.calls.count == 1)  // only the open
        await controller.handle(.opened(toc: [], openID: driver.lastOpenID))
        #expect(driver.calls.last == .go(passage, flash: true))
    }

    @Test("attaching the engine that is already attached changes nothing")
    func reattachingSameEngine() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book()
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.openShowing(book, on: driver)
        controller.attach(driver)
        #expect(controller.isReady && controller.isShowingBook)
        #expect(driver.opens == [book.id])
    }

    @Test("unchanged annotations aren't sent again; a reopen sends them afresh")
    func annotationsSentOnlyWhenChanged() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book()
        _ = try await lib.services.highlights.add(lib.passage("q", at: "h1"), in: book.id)
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.openShowing(book, on: driver)
        await controller.refreshAnnotations()
        await controller.refreshAnnotations()
        let shows = { driver.calls.filter { if case .show = $0 { true } else { false } }.count }
        #expect(shows() == 1)
        _ = try await lib.services.highlights.add(lib.passage("r", at: "h2"), in: book.id)
        await controller.refreshAnnotations()
        #expect(shows() == 2)
        // A new engine has drawn nothing yet.
        let reloaded = FakeDriver()
        controller.attach(reloaded)
        await controller.openShowing(book, on: reloaded)
        #expect(reloaded.lastAnnotations?.highlights.count == 2)
    }

    @Test("ready again from the same engine means it reloaded: the book reopens where it was")
    func engineReload() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book()
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.openShowing(book, on: driver)
        await controller.handle(.relocated(location("here", 0.3)))
        await controller.handle(.selectionChanged(lib.passage("words", at: "s"), anchor: anchor))

        await controller.handle(.ready)
        #expect(!controller.isShowingBook && controller.selection == nil)
        #expect(driver.calls.last == .open(book.id, Locator(scheme: FakeFormat.scheme, value: "here")))
        await controller.handle(.opened(toc: [], openID: driver.lastOpenID))
        #expect(controller.isShowingBook)
    }

    @Test("highlighting the selection clears its anchor too")
    func highlightClearsAnchor() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book()
        let controller = ReaderController(services: lib.services)
        let driver = FakeDriver()
        controller.attach(driver)
        await controller.openShowing(book, on: driver)
        await controller.handle(.selectionChanged(lib.passage("words", at: "s"), anchor: anchor))
        _ = try await controller.highlightSelection()
        #expect(controller.selectionAnchor == nil)
    }
}

@MainActor
struct PassageLinkRoundTripTests {
    @Test("notes → book: link words to a passage, save, and the marker appears")
    func linkGesture() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let app = AppModel(services: lib.services)
        let driver = FakeDriver()
        app.reader.attach(driver)
        await app.reader.openShowing(book, on: driver)

        let body = "camus is right about this"
        let document = MarkdownParser.standard.parse(body)
        let notes = NotesSelection(pageID: root.id, range: 9..<14)  // "right"
        #expect(app.linking.availability(notes: notes, document: document) == .needsBookSelection)
        let passage = lib.passage("one must imagine sisyphus happy", at: "cfi-1")
        await app.reader.handle(.selectionChanged(passage, anchor: ReaderRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(app.linking.availability(notes: notes, document: document) == .ready)

        let edit = try await app.linking.linkToPassage(notes: notes, document: document)
        let linked = edit.apply(to: body)
        let target = try #require(try await lib.store.read { try $0.linkTargets.linkTargets(in: book.id) }.first)
        #expect(linked == "camus is [right](gloss://passage/\(target.id)) about this")
        // No marker until the page is saved (abandoned links never show).
        await app.reader.refreshAnnotations()
        #expect(driver.lastAnnotations?.markers.isEmpty == true)

        try await lib.services.pages.updateBody(root.id, to: linked)
        await app.linking.didSaveLinkedPage()
        #expect(driver.lastAnnotations?.markers.map(\.id) == [target.id])
        #expect(driver.lastAnnotations?.markers.first?.locator.value == "cfi-1")
    }

    @Test("book → notes: a marker with one linking page opens it at the link")
    func markerOpensNote() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let app = AppModel(services: lib.services)
        let driver = FakeDriver()
        app.reader.attach(driver)
        await app.reader.openShowing(book, on: driver)
        let target = try await lib.services.links.target(for: lib.passage("q", at: "c"), in: book.id)
        let body = "intro line\nsee [this](gloss://passage/\(target.id)) here"
        try await lib.services.pages.updateBody(root.id, to: body)
        app.workspace.layout = .readerOnly

        await app.reader.handle(.annotationActivated(highlights: [], markers: [target.id], anchor: ReaderRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(app.workspace.page?.id == root.id)
        let range = try #require(app.workspace.pendingNoteReveal)
        #expect(MarkdownText(body)[range] == "[this](gloss://passage/\(target.id))")
        #expect(app.workspace.layout.showsNotes)  // reader-only switched to split
        app.workspace.consumeNoteReveal()
        #expect(app.workspace.pendingNoteReveal == nil)
    }

    @Test("book → notes: several linking pages offer a choice")
    func markerChoice() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let app = AppModel(services: lib.services)
        let driver = FakeDriver()
        app.reader.attach(driver)
        await app.reader.openShowing(book, on: driver)
        let target = try await lib.services.links.target(for: lib.passage("q", at: "c"), in: book.id)
        let link = "[q](gloss://passage/\(target.id))"
        try await lib.services.pages.updateBody(root.id, to: "root " + link)
        let sub = try await lib.services.pages.createSubpage(under: root.id, title: "sub")
        try await lib.services.pages.updateBody(sub.id, to: "sub " + link)

        await app.reader.handle(.annotationActivated(highlights: [], markers: [target.id], anchor: ReaderRect(x: 1, y: 2, width: 3, height: 4)))
        let choice = try #require(app.reader.markerChoice)
        #expect(Set(choice.pages.map(\.id)) == [root.id, sub.id])
        #expect(choice.anchor == ReaderRect(x: 1, y: 2, width: 3, height: 4))
        await app.reader.choose(choice.pages.first { $0.id == sub.id }!)
        #expect(app.reader.markerChoice == nil)
        #expect(app.workspace.page?.id == sub.id)
        #expect(app.workspace.pendingNoteReveal == 4..<(4 + link.utf16.count))
    }

    @Test("add to notes without an editor writes the quote line and draws the marker")
    func addToNotes() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let app = AppModel(services: lib.services)
        let driver = FakeDriver()
        app.reader.attach(driver)
        await app.reader.openShowing(book, on: driver)
        await expectThrows { try await app.linking.addSelectionToNotes(page: root.id) }
        await app.reader.handle(.selectionChanged(lib.passage("the absurd", at: "c9"), anchor: ReaderRect(x: 0, y: 0, width: 1, height: 1)))
        let saved = try await app.linking.addSelectionToNotes(page: root.id)
        #expect(saved.body.hasPrefix("> the absurd [↗](gloss://passage/"))
        #expect(driver.lastAnnotations?.markers.count == 1)

        // In an editor: the insertion is returned for the editor to apply (undoable).
        let (insertion, target) = try await app.linking.quoteInsertion(into: "ab", caret: 1)
        #expect(insertion.body == "a\n> the absurd [↗](gloss://passage/\(target.id))\nb")
    }

    func expectThrows(_ body: () async throws -> Void) async {
        do { try await body(); Issue.record("expected an error") } catch {}
    }
}
