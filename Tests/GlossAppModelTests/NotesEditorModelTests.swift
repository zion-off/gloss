import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossMarkdown
import GlossNotes
import GlossTestSupport

@MainActor
struct NotesEditorModelTests {
    func editor(_ lib: TestLibrary) -> NotesEditorModel {
        NotesEditorModel(services: lib.services, saveDelay: .zero)
    }

    /// Simulates the text view applying an edit the model returned.
    func apply(_ result: EditResult?, to model: NotesEditorModel) {
        guard let result else { return }
        model.textDidChange(result.apply(to: model.text), selection: result.selection)
    }

    @Test("loading shows the page, its breadcrumbs, styling and subpage rows")
    func loading() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book("Noces")
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "tipasa", appendBlockLine: true)
        let loose = try await lib.services.pages.createSubpage(under: root.id, title: "algiers")
        try await lib.services.pages.updateBody(root.id, to: "## summer\n" + (try await lib.services.pages.page(root.id)!.body))
        let model = editor(lib)
        try await model.load(try await lib.services.pages.page(child.id)!)
        #expect(model.breadcrumbs.map(\.title) == ["Noces", "tipasa"])

        try await model.load(try await lib.services.pages.page(root.id)!)
        #expect(model.subpageRows.map(\.title) == ["tipasa"])
        #expect(model.unplacedChildren.map(\.id) == [loose.id])
        #expect(model.spans.contains { $0.role == .heading(2) })
        #expect(model.saveState == .saved)
    }

    @Test("typing restyles, reveals syntax at the cursor and autosaves")
    func typing() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let model = editor(lib)
        try await model.load(root)
        model.textDidChange("a **bold** word", selection: 15..<15)
        #expect(model.saveState == .pending)
        #expect(!model.spans.contains { $0.role == .syntaxRevealed })
        model.selectionDidChange(5..<5)
        #expect(model.spans.filter { $0.role == .syntaxRevealed }.count == 2)
        #expect(model.activeFormats == ["bold"])
        await model.flushSave()
        #expect(model.saveState == .saved)
        #expect(try await lib.services.pages.page(root.id)?.body == "a **bold** word")
    }

    @Test("rapid typing always stores the newest text")
    func rapidTyping() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let model = NotesEditorModel(services: lib.services, saveDelay: .milliseconds(1))
        try await model.load(root)
        var text = ""
        for character in "one must imagine sisyphus happy" {
            text.append(character)
            model.textDidChange(text, selection: text.utf16.count..<text.utf16.count)
            if text.count % 5 == 0 { await Task.yield() }
        }
        await model.flushSave()
        #expect(try await lib.services.pages.page(root.id)?.body == "one must imagine sisyphus happy")
        #expect(model.saveState == .saved)
    }

    @Test("saves that change links redraw markers; other saves don't")
    func linkChanges() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let target = try await lib.services.links.target(for: lib.passage("q", at: "c"), in: book.id)
        let model = editor(lib)
        var redraws = 0
        model.linksDidChange = { redraws += 1 }
        try await model.load(root)
        model.textDidChange("plain", selection: 5..<5)
        await model.flushSave()
        #expect(redraws == 0)
        model.textDidChange("[q](gloss://passage/\(target.id))", selection: 0..<0)
        await model.flushSave()
        #expect(redraws == 1)
        #expect(model.spans.contains { $0.role == NotesRole.passageLink })
        model.textDidChange("[q](gloss://passage/\(target.id)) more", selection: 0..<0)
        await model.flushSave()
        #expect(redraws == 1)
    }

    @Test("links to trashed or missing things are styled as such")
    func linkStatuses() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "gone")
        _ = try await lib.services.trash.trash(.page, id: child.id.stringValue)
        try await lib.services.pages.updateBody(root.id, to: "[t](gloss://page/\(child.id)) [m](gloss://page/0000000000000000000000000z)")
        let model = editor(lib)
        try await model.load(try await lib.services.pages.page(root.id)!)
        let roles = Set(model.spans.map(\.role))
        #expect(roles.contains(NotesRole.trashedLink))
        #expect(roles.contains(NotesRole.brokenLink))
    }

    @Test("the slash menu opens, filters, moves, dismisses and runs")
    func slashMenu() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let model = editor(lib)
        try await model.load(root)
        model.textDidChange("note\n/", selection: 6..<6)
        #expect(model.slashMenu?.items.count == 10)
        model.textDidChange("note\n/to", selection: 8..<8)
        #expect(model.slashMenu?.items.first?.id == "todo")
        model.moveSlashSelection(by: -1)
        #expect(model.slashMenu?.selectedIndex == (model.slashMenu!.items.count - 1))
        model.moveSlashSelection(by: 1)
        let result = try #require(try await model.confirmSlashMenu())
        let applied = EditResult(edits: [result.edit], selection: result.selection)
        apply(applied, to: model)
        #expect(model.text == "note\n- [ ] ")
        #expect(model.slashMenu == nil)

        model.textDidChange("x /zz", selection: 5..<5)
        #expect(model.slashMenu == nil)  // nothing matches
        model.textDidChange("x /h", selection: 4..<4)
        #expect(model.slashMenu != nil)
        model.dismissSlashMenu()
        model.textDidChange("x /h1", selection: 5..<5)
        #expect(model.slashMenu == nil)  // dismissed until a new slash
        model.textDidChange("x /h1 /", selection: 7..<7)
        #expect(model.slashMenu != nil)
    }

    @Test("/page creates a subpage, places its row and asks to open it")
    func slashPage() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let model = editor(lib)
        try await model.load(root)
        model.textDidChange("/pa", selection: 3..<3)
        let result = try #require(try await model.confirmSlashMenu(itemID: "page"))
        let child = try #require(result.openPage)
        apply(EditResult(edits: [result.edit], selection: result.selection), to: model)
        #expect(model.subpageRows.map(\.pageID) == [child])
        await model.flushSave()
        #expect(try await lib.services.pages.unplacedChildren(of: root.id).isEmpty)
    }

    @Test("return, tab and task clicks produce list edits")
    func listKeys() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let model = editor(lib)
        try await model.load(root)
        model.textDidChange("- [ ] one", selection: 9..<9)
        apply(model.returnKey(), to: model)
        #expect(model.text == "- [ ] one\n- [ ] ")
        apply(model.tabKey(shift: false), to: model)
        #expect(model.text == "- [ ] one\n  - [ ] ")
        apply(model.tabKey(shift: true), to: model)
        #expect(model.isTaskBox(at: 3))
        apply(model.toggleTask(at: 3), to: model)
        #expect(model.text.hasPrefix("- [x] one"))
        model.textDidChange("plain", selection: 5..<5)
        #expect(model.returnKey() == nil)
        #expect(model.tabKey(shift: false) == nil)
    }

    @Test("links and rows under the pointer, and passage previews")
    func pointer() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book("Caligula")
        let target = try await lib.services.links.target(for: lib.passage("the moon", at: "c"), in: book.id)
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "acts")
        let body = "[moon](gloss://passage/\(target.id)) and [web](https://x.y)\n[acts](gloss://page/\(child.id))"
        try await lib.services.pages.updateBody(root.id, to: body)
        let model = editor(lib)
        try await model.load(try await lib.services.pages.page(root.id)!)
        #expect(model.glossLink(at: 2) == .passage(target.id))
        let web = body.utf16.distance(from: body.utf16.startIndex, to: body.range(of: "[web]")!.lowerBound.samePosition(in: body.utf16)!) + 1
        #expect(model.linkDestination(at: web) == "https://x.y")
        #expect(model.glossLink(at: web) == nil)
        let preview = try #require(await model.preview(at: 2))
        #expect(preview.quote == "the moon")
        #expect(preview.documentTitle == "Caligula")
        let rowOffset = body.utf16.count - 2
        #expect(model.subpageRow(at: rowOffset)?.pageID == child.id)
    }

    @Test("external changes reload a clean editor but never clobber unsaved typing")
    func externalChanges() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let model = NotesEditorModel(services: lib.services, saveDelay: .seconds(60))
        try await model.load(root)
        try await lib.services.pages.updateBody(root.id, to: "from the cli")
        await model.pageChangedExternally()
        #expect(model.text == "from the cli")

        model.textDidChange("my typing", selection: 9..<9)
        try await lib.services.pages.updateBody(root.id, to: "cli again")
        await model.pageChangedExternally()
        #expect(model.text == "my typing")
        await model.flushSave()
        #expect(try await lib.services.pages.page(root.id)?.body == "my typing")
    }

    @Test("a failed save stays dirty: flushes retry it and external changes don't clobber it")
    func failedSaveStaysDirty() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "draft")
        let model = NotesEditorModel(services: lib.services, saveDelay: .seconds(60))
        try await model.load(child)
        model.textDidChange("my typing", selection: 9..<9)
        let entry = try await lib.services.trash.trash(.page, id: child.id.stringValue)
        await model.flushSave()
        guard case .failed = model.saveState else { Issue.record("expected a failed save, got \(model.saveState)"); return }
        #expect(model.isDirty)

        // Back from the trash and changed by the cli: the typing still wins, and the change
        // is the cue to retry the save.
        _ = try await lib.services.trash.restore(entry.id)
        try await lib.services.pages.updateBody(child.id, to: "meanwhile, from the cli")
        await model.pageChangedExternally()
        #expect(model.text == "my typing")
        #expect(model.saveState == .saved)
        #expect(try await lib.services.pages.page(child.id)?.body == "my typing")
    }

    @Test("a flush after a failed save writes the text")
    func flushRetriesFailedSave() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "draft")
        let model = NotesEditorModel(services: lib.services, saveDelay: .seconds(60))
        try await model.load(child)
        model.textDidChange("keep me", selection: 7..<7)
        let entry = try await lib.services.trash.trash(.page, id: child.id.stringValue)
        await model.flushSave()
        _ = try await lib.services.trash.restore(entry.id)
        await model.flushSave()
        #expect(model.saveState == .saved)
        #expect(try await lib.services.pages.page(child.id)?.body == "keep me")
    }

    @Test("a page trashed elsewhere with nothing unsaved unloads")
    func trashedElsewhereUnloads() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "draft")
        try await lib.services.pages.updateBody(child.id, to: "# saved")
        let model = editor(lib)
        try await model.load(try await lib.services.pages.page(child.id)!)
        _ = try await lib.services.trash.trash(.page, id: child.id.stringValue)
        await model.pageChangedExternally()
        #expect(model.page == nil)
        #expect(model.text.isEmpty && model.spans.isEmpty && model.breadcrumbs.isEmpty)
        #expect(model.saveState == .saved)
    }

    @Test("a failed link lookup doesn't style live links as broken")
    func failedLookupIsNotBroken() async throws {
        let memory = TestLibrary()
        let flaky = FlakyLibraryStore(memory.store)
        let services = GlossServices(store: flaky, blobs: memory.blobs, formats: memory.services.formats,
                                     ids: memory.services.ids, time: memory.clock)
        let (_, root) = try await memory.book()
        let a = try await services.pages.createSubpage(under: root.id, title: "a")
        let b = try await services.pages.createSubpage(under: root.id, title: "b")
        try await services.pages.updateBody(root.id, to: "[a](gloss://page/\(a.id))")
        let model = NotesEditorModel(services: services, saveDelay: .seconds(60))
        try await model.load(try await services.pages.page(root.id)!)
        #expect(!model.spans.contains { $0.role == NotesRole.brokenLink })

        flaky.failsReads = true
        let body = "[a](gloss://page/\(a.id)) [b](gloss://page/\(b.id))"
        model.textDidChange(body, selection: 0..<0)
        await model.flushSave()
        #expect(model.saveState == .saved)
        #expect(!model.spans.contains { $0.role == NotesRole.brokenLink })
    }

    @Test("switching pages after a save failed keeps the text until the user lets it go")
    func switchingWithUnsavedText() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "draft")
        let model = NotesEditorModel(services: lib.services, saveDelay: .seconds(60))
        try await model.load(child)
        model.textDidChange("precious", selection: 8..<8)
        _ = try await lib.services.trash.trash(.page, id: child.id.stringValue)

        await #expect(throws: NotesEditorModel.EditorError.unsavedChanges("this page is in the trash")) {
            try await model.load(root)
        }
        #expect(model.page?.id == child.id && model.text == "precious")

        try await model.load(root, discardingUnsaved: true)
        #expect(model.page?.id == root.id && model.saveState == .saved)
    }
}

