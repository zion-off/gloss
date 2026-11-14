import Foundation
import Testing
@testable import GlossAppModel
import GlossCore
import GlossMemoryStore
import GlossTestSupport
import GlossReaderBridge

/// A mutable box a notification observer can write to. Delivery is synchronous on the posting
/// thread (verified against swift-corelibs-foundation), so no lock is needed.
final class Note<T>: @unchecked Sendable {
    var value: T?
    init(_ value: T? = nil) { self.value = value }
}

@MainActor
struct DeletionModelTests {
    @Test("trashing publishes the undo toast; undo restores and clears it")
    func toastAndUndo() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book("Moby-Dick")
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "queequeg")
        let deletion = DeletionModel(services: lib.services, sleep: { _ in })

        let entry = try #require(await deletion.trash(kind: .page, id: child.id.stringValue))
        #expect(entry.title == "queequeg")
        #expect(deletion.toast?.message == "“queequeg” moved to the trash")
        #expect(deletion.toast?.entry?.id == entry.id)
        #expect(try await lib.services.pages.page(child.id)?.trash != nil)

        let restored = await deletion.undo(entry)
        #expect(restored?.map(\.id) == [entry.id])
        #expect(deletion.toast == nil)
        #expect(try await lib.services.pages.page(child.id)?.trash == nil)
    }

    @Test("the toast goes away on its own, and a newer toast replaces an older one")
    func toastLifecycle() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let a = try await lib.services.pages.createSubpage(under: root.id, title: "a")
        let b = try await lib.services.pages.createSubpage(under: root.id, title: "b")
        let deletion = DeletionModel(services: lib.services, sleep: { _ in })

        _ = await deletion.trash(kind: .page, id: a.id.stringValue)
        let second = try #require(await deletion.trash(kind: .page, id: b.id.stringValue))
        #expect(deletion.toast?.entry?.id == second.id)  // replaced, not stacked
        await deletion.flushToastDismissal()
        #expect(deletion.toast == nil)

        // A toast the user dismissed stays gone; a newer toast starts its own clock.
        _ = await deletion.trash(kind: .page, id: a.id.stringValue)
        deletion.dismissToast()
        #expect(deletion.toast == nil)
        await deletion.flushToastDismissal()
        #expect(deletion.toast == nil)
    }

    @Test("undo works after the toast went away, and a missing entry is a quiet no-op")
    func undoAfterDismissal() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "gone")
        let deletion = DeletionModel(services: lib.services, sleep: { _ in })
        let entry = try #require(await deletion.trash(kind: .page, id: child.id.stringValue))
        await deletion.flushToastDismissal()
        #expect(await deletion.undo(entry) != nil)
        #expect(try await lib.services.pages.page(child.id)?.trash == nil)
        // Undoing again (the entry is out of the trash) changes nothing and stays quiet.
        #expect(await deletion.undo(entry) == nil)
    }

    @Test("a page that can't be trashed says why, and nothing goes")
    func failures() async throws {
        let lib = TestLibrary()
        let (_, root) = try await lib.book("A Book")
        let deletion = DeletionModel(services: lib.services, sleep: { _ in })
        #expect(await deletion.trash(kind: .page, id: root.id.stringValue) == nil)
        #expect(deletion.toast?.entry == nil)
        #expect(deletion.toast?.message ==
                "a book's main notes page can't be trashed on its own — trash the book instead")
        #expect(try await lib.services.trash.entries().isEmpty)
    }
}

@MainActor
struct AppModelTrashTests {
    @Test("trashing the open book closes it everywhere and updates the badge and the grid")
    func trashOpenDocument() async throws {
        let lib = TestLibrary()
        let (book, _) = try await lib.book("External")
        let app = AppModel(services: lib.services)
        let driver = FakeDriver()
        app.reader.attach(driver)
        try await app.workspace.openDocument(book.id)
        await app.showReaderFocus()
        await app.reader.openShowing(book, on: driver)
        await app.reader.handle(.relocated(ReaderLocation(locator: Locator(scheme: FakeFormat.scheme, value: "here"),
                                                          progression: 0.3, label: nil, progressText: "")))
        await app.reader.flushPosition()
        await app.library.reload()
        await app.trash.reload()
        #expect(app.library.entries.map(\.document.title) == ["External"])

        let entry = try #require(await app.moveToTrash(book))
        #expect(app.deletion.toast?.message == "“External” moved to the trash")
        #expect(app.workspace.document == nil)          // the workspace dropped it
        #expect(app.workspace.sidebar == .library(nil)) // the grid shows
        #expect(app.reader.document == nil)              // and the reader's session blanked
        #expect(app.reader.location == nil)
        #expect(driver.calls.last == .close)
        #expect(app.trash.items.count == 1)              // the sidebar badge
        #expect(app.library.entries.isEmpty)             // the grid lost it
        // Undo brings the book back, open where it was.
        let restored = try #require(await app.undoTrash(entry))
        #expect(!restored.isEmpty)
        #expect(app.workspace.document?.id == book.id)
        #expect(app.trash.items.isEmpty)
        #expect(app.library.entries.map(\.document.title) == ["External"])
    }

    @Test("trashing a book that isn't open leaves the window alone")
    func trashOtherDocument() async throws {
        let lib = TestLibrary()
        let (a, _) = try await lib.book("A")
        let (b, _) = try await lib.book("B")
        let app = AppModel(services: lib.services)
        try await app.workspace.openDocument(a.id)
        await app.library.reload()
        _ = await app.moveToTrash(b)
        #expect(app.workspace.document?.id == a.id)
        #expect(app.library.entries.map(\.document.title) == ["A"])
        #expect(app.trash.items.count == 1)
    }

    @Test("trashing the open page lands on its parent; undo goes back to it")
    func trashOpenPage() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "child")
        let grandchild = try await lib.services.pages.createSubpage(under: child.id, title: "grandchild")
        let app = AppModel(services: lib.services)
        try await app.workspace.openDocument(book.id)
        await app.bookSidebar.load(book.id)

        // The open page itself goes: land on its parent.
        try await app.workspace.openPage(grandchild.id)
        let grandchildEntry = try #require(await app.moveToTrash(pageID: grandchild.id))
        #expect(app.workspace.page?.id == child.id)
        #expect(app.workspace.sidebar == .page(child.id))

        // Undo returns to the page that was on screen before the trash.
        _ = try #require(await app.undoTrash(grandchildEntry))
        #expect(app.workspace.page?.id == grandchild.id)
        #expect(try await lib.services.pages.page(grandchild.id)?.trash == nil)

        // A page with the open page inside it goes: land on the parent again.
        let childEntry = try #require(await app.moveToTrash(pageID: child.id))
        #expect(app.workspace.page?.id == root.id)  // the grandchild went with the child
        #expect(app.workspace.sidebar == .page(root.id))
        _ = try #require(await app.undoTrash(childEntry))
        // The restored entry's page shows (the cascade — grandchild included — is back too).
        #expect(app.workspace.page?.id == child.id)
        #expect(try await lib.services.pages.page(grandchild.id)?.trash == nil)
    }

    @Test("a vanished page lands on its parent, else its book's main page, else the reader's book")
    func landing() async throws {
        let lib = TestLibrary()
        let (a, aRoot) = try await lib.book("A")
        let (b, bRoot) = try await lib.book("B")
        let app = AppModel(services: lib.services)
        try await app.workspace.openDocument(a.id)  // the reader shows A

        // The vanished page's parent is alive: land there, even though the reader shows A.
        let bChild = try await lib.services.pages.createSubpage(under: bRoot.id, title: "b child")
        await app.landNotes(afterVanishing: (parentID: bChild.parentID, documentID: b.id))
        #expect(app.workspace.page?.id == bRoot.id)

        // Parent gone but the book alive: land on the book's main page.
        _ = try await lib.services.trash.trash(.document, id: b.id.stringValue)
        try await app.workspace.openDocument(a.id)
        await app.landNotes(afterVanishing: (parentID: bChild.parentID, documentID: b.id))
        #expect(app.workspace.page?.id == aRoot.id)  // everything in B is trashed: follow the reader
        _ = a
    }

    @Test("a page trashed elsewhere lands the notes pane too")
    func externalLanding() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "child")
        let app = AppModel(services: lib.services)
        try await app.workspace.openDocument(book.id)
        try await app.workspace.openPage(child.id)

        // The "cli" trashes the open page behind the window's back.
        _ = try await lib.services.trash.trash(.page, id: child.id.stringValue)
        let change = ChangeRecord(sequence: 1, entity: ChangeEntity.page, entityID: child.id.stringValue,
                                  origin: "cli", date: .testEpoch)
        await app.handleExternalChanges([change])
        #expect(app.workspace.page?.id == root.id)
    }

    @Test("the root page explains itself instead of going anywhere")
    func trashRootPage() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let app = AppModel(services: lib.services)
        try await app.workspace.openDocument(book.id)
        #expect(await app.moveToTrash(pageID: root.id) == nil)
        #expect(app.deletion.toast?.entry == nil)
        #expect(app.workspace.page?.id == root.id)
        #expect(app.trash.items.isEmpty)
    }
}

// Serialized: every test here drives the Settings window's model, whose saves post
// `glossSettingsChanged` to every AppModel in the process (by design — the app has one
// Settings window). Concurrent tests would hear each other's posts land on their own
// books, so the exact-order assertions below need this suite to itself.
@Suite(.serialized)
@MainActor
struct AppSettingsModelTests {
    @Test("settings load with defaults, persist every change in the library, and announce it")
    func loadAndSave() async throws {
        let lib = TestLibrary()
        let settings = AppSettingsModel(services: lib.services, sleep: { _ in })
        await settings.load()
        #expect(settings.retentionDays == 30)
        #expect(settings.reader == ReaderSettings())

        // What the notification carries, synchronously (verified on Linux and Darwin).
        let announced = Note<ReaderSettings>()
        let token = NotificationCenter.default.addObserver(forName: .glossSettingsChanged, object: settings, queue: nil) { note in
            announced.value = note.glossReaderSettings
        }
        defer { NotificationCenter.default.removeObserver(token) }

        settings.retentionDays = 7
        settings.reader.fontSize = 21
        await settings.flushSave()

        #expect(announced.value?.fontSize == 21)
        #expect(try await lib.services.settings.value(TrashSettings.retentionDays) == 7)
        let stored = try await ReaderSettingsStore(settings: lib.services.settings).load()
        #expect(stored.fontSize == 21)
        #expect(stored.theme == ReaderSettings().theme)  // untouched fields keep their value

        // A fresh model reads back the same thing.
        let fresh = AppSettingsModel(services: lib.services, sleep: { _ in })
        await fresh.load()
        #expect(fresh.retentionDays == 7)
        #expect(fresh.reader.fontSize == 21)

        // "never" is a choice too.
        settings.retentionDays = nil
        await settings.flushSave()
        #expect(try await lib.services.settings.value(TrashSettings.retentionDays) == nil)
    }

    @Test("a failed save announces nothing and says so (review 7)")
    func failedSaveIsHonest() async throws {
        let clock = ManualTimeSource()
        let base = InMemoryLibraryStore(origin: "test", time: clock)
        let flaky = FlakyLibraryStore(base)
        let blobs = InMemoryBlobStore()
        let services = GlossServices(store: flaky, blobs: blobs, formats: FormatRegistry([FakeFormat()]),
                                     ids: SequentialIDGenerator(), time: clock)
        let settings = AppSettingsModel(services: services, sleep: { _ in })
        await settings.load()
        let posts = Note<Int>(0)
        let token = NotificationCenter.default.addObserver(forName: .glossSettingsChanged, object: settings, queue: nil) { [posts] _ in
            posts.value! += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        flaky.failsWrites = true  // the settings write itself fails
        settings.retentionDays = 90
        await settings.flushSave()
        #expect(posts.value == 0)  // nothing stored: nothing announced
        #expect(settings.saveProblem != nil)  // and the Settings window gets to say so
        flaky.failsWrites = false
        settings.retentionDays = 7
        await settings.flushSave()
        #expect(posts.value == 1)
        #expect(settings.saveProblem == nil)
    }

    @Test("rapid changes save once, and load itself doesn't save")
    func debounce() async throws {
        let lib = TestLibrary()
        let settings = AppSettingsModel(services: lib.services, sleep: { _ in })
        await settings.load()
        let posts = Note<Int>(0)
        let token = NotificationCenter.default.addObserver(forName: .glossSettingsChanged, object: settings, queue: nil) { [posts] _ in
            posts.value! += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(posts.value == 0)  // loading what's stored must not announce anything

        for size in stride(from: 12.0, through: 24.0, by: 1.0) { settings.reader.fontSize = size }
        settings.retentionDays = 90
        await settings.flushSave()
        #expect(posts.value == 1)  // one save for the whole drag
        #expect(try await lib.services.settings.value(TrashSettings.retentionDays) == 90)
        #expect(try await ReaderSettingsStore(settings: lib.services.settings).load().fontSize == 24)
    }

    @Test("a window applies the settings to its open book when Settings closes, and re-dates its trash")
    func liveApplication() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book()
        let page = try await lib.services.pages.createSubpage(under: root.id, title: "bye")
        _ = try await lib.services.trash.trash(.page, id: page.id.stringValue)
        let app = AppModel(services: lib.services)
        let driver = FakeDriver()
        app.reader.attach(driver)
        await app.reader.openShowing(book, on: driver)
        await app.trash.reload()
        #expect(app.trash.items.first?.expiresAt != nil)
        // The driver is attached but the book is not "showing" until the controller takes the
        // open; openShowing did that. Settings saved by the Settings window reach it live:

        // The Settings window (another window, same process) saves.
        let settings = AppSettingsModel(services: lib.services, sleep: { _ in })
        await settings.load()
        settings.reader.theme = .night
        settings.retentionDays = nil
        await settings.flushSave()
        await app.flushSettingsChanges()
        // The flush (the window closing) announced the final settings once: the open book took
        // the night theme the settings ended on.
        #expect(!driver.appliedAppearances.isEmpty)
        #expect(driver.appliedAppearances.last?.colors.background == "#1c1c1e")
        #expect(app.trash.items.first?.expiresAt == nil)  // "kept until you empty the trash"
        #expect(app.trash.items.first?.expiresAt == nil)  // "kept until you empty the trash"
    }

    @Test("two saves apply in the order they were saved")
    func savesApplyInOrder() async throws {
        let clock = ManualTimeSource()
        let base = InMemoryLibraryStore(origin: "test", time: clock)
        let flaky = FlakyLibraryStore(base)
        let blobs = InMemoryBlobStore()
        let services = GlossServices(store: flaky, blobs: blobs, formats: FormatRegistry([FakeFormat()]),
                                     ids: SequentialIDGenerator(), time: clock)
        let outcome = try await services.imports.importData(FakeFormat.file(title: "The Fall"), filename: "a.fake")
        let app = AppModel(services: services)
        let driver = FakeDriver()
        app.reader.attach(driver)
        await app.reader.openShowing(outcome.document, on: driver)

        let settings = AppSettingsModel(services: services, sleep: { _ in })
        await settings.load()
        var night = ReaderSettings(); night.theme = .night
        var light = ReaderSettings(); light.theme = .light
        flaky.parkNextRead = true  // the first reaction's trash reload parks mid-read
        settings.reader = night
        await settings.flushSave()
        settings.reader = light
        await settings.flushSave()
        while flaky.parkedReads < 1 { await Task.yield() }  // the first reaction is parked
        // Give an unchained second reaction every chance to run past the parked first one:
        // if it can, it applies its (newer) settings while the older reaction still waits.
        for _ in 0..<200 { await Task.yield() }
        flaky.releaseParkedRead()
        await app.flushSettingsChanges()
        // Chained, the saves land in order: night first, light last. Unchained, the newer
        // reaction finishes while the older is parked and the stale night theme lands last.
        let styler = AppearanceStyler()
        #expect(driver.appliedAppearances.map(\.colors.background)
                == [styler.appearance(for: night).colors.background,
                    styler.appearance(for: light).colors.background])
    }

    @Test("quick changes with the real sleep cancel the pending save without crashing")
    func quickChangesWithTheRealSleep() async throws {
        let lib = TestLibrary()
        let settings = AppSettingsModel(services: lib.services, saveDelay: .milliseconds(50))
        await settings.load()
        let posts = Note<Int>(0)
        let token = NotificationCenter.default.addObserver(forName: .glossSettingsChanged, object: settings, queue: nil) { [posts] _ in
            posts.value! += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        for size in 15...19 {
            settings.reader.fontSize = Double(size)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))
        let stored = try await ReaderSettingsStore(settings: lib.services.settings).load()
        #expect(stored.fontSize == 19)
        #expect(posts.value == 0)  // stored, but open books wait for the window to close
        await settings.flushSave()  // the window closes
        #expect(posts.value == 1)
        await settings.flushSave()  // nothing changed since: nothing more to apply
        #expect(posts.value == 1)
    }
}

@MainActor
struct BackupModelTests {
    @Test("the default file name is the cli's shape")
    func naming() {
        let name = LibraryBackupNaming.fileName(for: Date(timeIntervalSince1970: 1_763_000_000))
        #expect(name.range(of: #"^gloss backup \d{4}-\d{2}-\d{2} \d{4}\.sqlite$"#,
                          options: .regularExpression) != nil)
        // Two minutes apart never collide.
        #expect(LibraryBackupNaming.fileName(for: Date(timeIntervalSince1970: 0))
                != LibraryBackupNaming.fileName(for: Date(timeIntervalSince1970: 61)))
    }

    @Test("backing up writes the file and reports success")
    func backup() async throws {
        let lib = TestLibrary()
        _ = try await lib.book("Noces")
        let model = BackupModel(services: lib.services)
        #expect(model.canBackUp)
        let directory = TempDir()
        let url = directory.file("copy.sqlite")
        await model.backUp(to: url)
        #expect(model.state == .done(url))
        #expect(FileManager.default.fileExists(atPath: url.path))
        model.clearResult()
        #expect(model.state == .idle)
    }

    @Test("an existing file is never overwritten")
    func neverOverwrites() async throws {
        let lib = TestLibrary()
        let model = BackupModel(services: lib.services)
        let directory = TempDir()
        let url = directory.file("copy.sqlite")
        try Data("mine".utf8).write(to: url)
        await model.backUp(to: url)
        guard case .failed = model.state else {
            Issue.record("expected a failure, got \(model.state)")
            return
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine")
    }
}

@MainActor
struct TrashModelMessageTests {
    @Test("restoring says what came back, including the cascade")
    func restoreMessage() async throws {
        let lib = TestLibrary()
        let (book, root) = try await lib.book("Moby-Dick")
        let child = try await lib.services.pages.createSubpage(under: root.id, title: "loomings")
        let entry = try await lib.services.trash.trash(.page, id: child.id.stringValue)
        let model = TrashModel(services: lib.services)
        await model.reload()
        #expect(model.lastRestoredMessage == nil)
        await model.restore(entry.id)
        #expect(model.lastRestoredMessage == "restored “loomings”")
        _ = book

        // A page under a trashed book brings the book back too: both are named.
        let (other, otherRoot) = try await lib.book("Exile")
        let page = try await lib.services.pages.createSubpage(under: otherRoot.id, title: "tipasa")
        let pageEntry = try await lib.services.trash.trash(.page, id: page.id.stringValue)
        _ = try await lib.services.trash.trash(.document, id: other.id.stringValue)
        await model.restore(pageEntry.id)
        #expect(model.lastRestoredMessage == "restored “tipasa” and 1 more")
    }
}
