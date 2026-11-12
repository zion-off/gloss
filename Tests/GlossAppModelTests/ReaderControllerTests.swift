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
        case go(Locator, flash: Bool)
        case turn(forward: Bool)
        case show(ReaderAnnotations)
        case clearSelection
        case reveal(Locator?, String)
    }

    var calls: [Call] = []
    var failGo = false

    func open(_ document: Document, at position: Locator?) async throws { calls.append(.open(document.id, position)) }
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
        await controller.handle(.opened(toc: [ReaderTocEntry(label: "one", target: Locator(scheme: FakeFormat.scheme, value: "t1"))]))
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
        await controller.handle(.opened(toc: []))
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
        controller.attach(FakeDriver())
        await controller.open(book)
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
        await controller.handle(.ready)
        await controller.open(book)
        await controller.handle(.opened(toc: []))
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
        await controller.handle(.ready)
        await controller.open(book)
        await controller.handle(.opened(toc: []))
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
        await controller.handle(.ready)
        await controller.open(book)
        await controller.go(to: Locator(scheme: LocatorScheme("weird"), value: "x"))
        #expect(controller.errorMessage == "the reader can't go there")
        await controller.handle(.externalLink(URL(string: "https://example.com")!))
        #expect(opened == [URL(string: "https://example.com")!])
        await controller.handle(.failed("open: 404"))
        #expect(controller.errorMessage == "open: 404")
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
        await app.reader.handle(.ready)
        await app.reader.open(book)
        await app.reader.handle(.opened(toc: []))

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
        app.reader.attach(FakeDriver())
        await app.reader.handle(.ready)
        await app.reader.open(book)
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
        app.reader.attach(FakeDriver())
        await app.reader.handle(.ready)
        await app.reader.open(book)
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
        await app.reader.handle(.ready)
        await app.reader.open(book)
        await app.reader.handle(.opened(toc: []))
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
