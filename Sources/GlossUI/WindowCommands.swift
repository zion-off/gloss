#if os(macOS)
import SwiftUI
import GlossAppModel
import GlossCore
import GlossEditor
import GlossMarkdown

/// The window's commands that need the focused pane: "link to passage" (⌘K) and "add to
/// notes" act on the notes editor and the book selection; back/forward (⌘[ ⌘]) follow whichever
/// pane has focus. Enabled state comes from the models, so a disabled command explains itself.
@MainActor @Observable
public final class WindowCommands {
    @ObservationIgnored weak var app: AppModel?
    /// Which pane takes ⌘[ / ⌘]: the notes editor's focus state, else the reader.
    public internal(set) var notesFocused = false

    public init() {}

    public func bind(_ app: AppModel) {
        self.app = app
    }

    // MARK: Linking

    public var canLink: Bool { app?.linkAvailability.isEnabled ?? false }
    public var linkHint: String { app?.linkAvailability.hint ?? "" }

    public func linkToPassage() {
        guard let app else { return }
        Task {
            if let edit = try? await app.linkSelectionToPassage() { editor?.apply(edit) }
        }
    }

    public var canQuote: Bool { app?.reader.selection != nil }

    /// Into the editor at the caret when it shows the book's page, else straight to the page.
    public func addToNotes() async {
        guard let app else { return }
        if let edit = try? await app.addReaderSelectionToNotes() { editor?.apply(edit) }
    }

    // MARK: Layout

    public var layout: SplitLayout {
        get { app?.workspace.layout ?? .split }
        set { app?.workspace.layout = newValue }
    }

    // MARK: History

    public var canGoBack: Bool { notesFocused ? (app?.workspace.canGoBackInNotes ?? false) : (app?.workspace.canGoBackInReader ?? false) }
    public var canGoForward: Bool { notesFocused ? (app?.workspace.canGoForwardInNotes ?? false) : (app?.workspace.canGoForwardInReader ?? false) }

    public func goBack() {
        guard let app else { return }
        Task {
            if notesFocused { try? await app.workspace.goBackInNotes() } else { try? await app.workspace.goBackInReader() }
        }
    }

    public func goForward() {
        guard let app else { return }
        Task {
            if notesFocused { try? await app.workspace.goForwardInNotes() } else { try? await app.workspace.goForwardInReader() }
        }
    }

    /// The window's notes editor, while one is on screen (set by the notes pane).
    @ObservationIgnored weak var editor: NotesEditorActions?
}

/// The commands themselves. ⌘K is the plan's Edit-menu "link to passage"; ⌘[ / ⌘] are the
/// system's history shortcuts (Safari, Finder), never taken from a system menu.
public struct GlossWindowCommands: Commands {
    @FocusedValue(\.windowCommands) private var commands: WindowCommands?

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Self.layouts, id: \.layout) { entry in
                Toggle(entry.title, isOn: Binding(get: { commands?.layout == entry.layout },
                                                  set: { if $0 { commands?.layout = entry.layout } }))
                    .keyboardShortcut(entry.key, modifiers: [.command, .option])
                    .disabled(commands == nil)
            }
        }
        CommandMenu("go") {
            Button("back") { commands?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(commands?.canGoBack != true)
            Button("forward") { commands?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(commands?.canGoForward != true)
        }
        CommandGroup(after: .textFormatting) {
            Divider()
            Button("link to passage") { commands?.linkToPassage() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(commands?.canLink != true)
                .help(commands?.linkHint ?? "")
            Button("add to notes") { Task { await commands?.addToNotes() } }
                .disabled(commands?.canQuote != true)
                .help("the book's selection, quoted at the cursor")
        }
    }
}

extension GlossWindowCommands {
    /// The View menu's layout items, Preview-style ⌥⌘ numbers (D-095).
    static let layouts: [(layout: SplitLayout, title: String, key: KeyEquivalent)] = [
        (.split, "reader and notes", "1"),
        (.readerOnly, "reader only", "2"),
        (.notesOnly, "notes only", "3"),
    ]
}

extension FocusedValues {
    /// The key window's commands.
    @Entry public var windowCommands: WindowCommands?
}
#endif
