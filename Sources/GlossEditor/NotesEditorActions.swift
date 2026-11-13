#if os(macOS)
import SwiftUI
import GlossCore
import GlossMarkdown
import GlossNotes

/// What the editor's overlays and the Format menu can ask of the text view. Every edit goes
/// through the coordinator, so it reaches the text view's change APIs and undo records it as
/// one step (review: clicks used to replace the text behind undo's back).
@MainActor @Observable public final class NotesEditorActions {
    @ObservationIgnored weak var coordinator: NotesEditorCoordinator?
    /// The notes text view has keyboard focus (the Format menu and ⌘[ are enabled only then).
    public internal(set) var isEditing = false
    /// Called whenever the focus state changes (the window routes history shortcuts by it).
    public var onFocusChange: ((Bool) -> Void)?

    public init() {}

    /// A format bar button or Format menu item.
    public func run(_ item: FormatBarItem) {
        coordinator?.run(item.command)
    }

    /// Applies an edit made elsewhere in the window (⌘K, add to notes) through the text view,
    /// as one undo step. Nothing happens when no editor is on screen.
    public func apply(_ edit: EditResult) {
        coordinator?.apply(edit)
    }

    /// A click on a slash menu row.
    func confirmSlash(_ itemID: String?) async {
        await coordinator?.confirmSlashMenu(itemID: itemID)
    }

    /// The editor's focus state changed.
    /// Puts the caret at the start of the body (Return in the page title moves here).
    public func focusBody() {
        coordinator?.focusBody()
    }

    func focusChanged(_ focused: Bool) {
        isEditing = focused
        onFocusChange?(focused)
    }
}

/// A selection the editor should show once, on a given page (a marker click in the book).
public struct NotesReveal: Equatable, Sendable {
    public let token: UUID
    public let pageID: PageID
    public let range: Range<Int>

    public init(pageID: PageID, range: Range<Int>) {
        self.token = UUID()
        self.pageID = pageID
        self.range = range
    }
}

extension FocusedValues {
    /// The focused window's notes editor, for the Format menu.
    @Entry public var notesEditorActions: NotesEditorActions?
}

/// The Format menu: the format bar's commands with Apple Notes' shortcuts (D-070). It replaces
/// the system's text formatting group, whose Font › Bold would set rich-text traits that the
/// markdown buffer can't hold.
public struct NotesFormatCommands: Commands {
    @FocusedValue(\.notesEditorActions) private var actions

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .textFormatting) {
            ForEach(FormatBar.items) { item in
                Button(item.title) { actions?.run(item) }
                    .keyboardShortcut(KeyEquivalent(item.key), modifiers: item.shift ? [.command, .shift] : .command)
                    .disabled(actions?.isEditing != true)
            }
        }
    }
}
#endif
