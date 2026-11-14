#if os(macOS)
import AppKit
import SwiftUI
import GlossAppModel
import GlossCore

extension AppModel {
    /// Registers "move to trash"'s undo with the window's undo manager, so ⌘Z works after the
    /// toast is gone. The undo manager is a Mac-only type, so this lives here and not
    /// in the portable model.
    public func registerTrashUndo(_ entry: TrashEntry, undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [entry] app in
            Task { await app.undoTrash(entry) }
        }
        // Named after registering: setActionName attaches to the most recent registration, so
        // the earlier order renamed the previous action and left this one a bare "Undo".
        undoManager.setActionName("move to trash")
    }

    /// Moves a page to the trash and registers ⌘Z. For menus and commands.
    public func trashPage(_ id: PageID, undoManager: UndoManager?) {
        Task {
            guard let entry = await moveToTrash(pageID: id) else { return }
            registerTrashUndo(entry, undoManager: undoManager)
        }
    }

    /// Moves a book to the trash and registers ⌘Z. For menus and commands.
    public func trashBook(_ document: Document, undoManager: UndoManager?) {
        Task {
            guard let entry = await moveToTrash(document) else { return }
            registerTrashUndo(entry, undoManager: undoManager)
        }
    }

    /// The library grid's "move to trash" menu item, handed over in one line:
    /// `LibraryGrid(…, moveToTrash: app.trashBookAction(undo: undoManager))`.
    public func trashBookAction(undoManager: UndoManager?) -> @MainActor (Document) -> Void {
        { [self] document in self.trashBook(document, undoManager: undoManager) }
    }
}

/// The undo toast at the bottom of the window: a system-material capsule that says
/// what moved to the trash, offers undo, and goes away on its own after a few seconds (the
/// model owns the timing; this only renders it).
struct TrashToastOverlay: View {
    let app: AppModel

    var body: some View {
        Group {
            if let toast = app.deletion.toast {
                HStack(spacing: 12) {
                    Text(verbatim: toast.message)
                        .lineLimit(2)
                    if let entry = toast.entry {
                        Divider().frame(height: 14)
                        Button("undo") { Task { await app.undoTrash(entry) } }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear { announce(toast.message) }
            }
        }
        .animation(.snappy, value: app.deletion.toast)
    }

    /// VoiceOver hears what the toast said — the one verified announcement API
    /// (`NSAccessibility.post`, macOS 10.7+). The element is the app object; a run has to
    /// confirm it reads naturally (handoff).
    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: message])
    }
}
#endif
