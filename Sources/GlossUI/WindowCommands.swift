import SwiftUI
import GlossAppModel
import GlossCore
import GlossEditor
import GlossMarkdown

/// The window's commands that need the focused pane: "link to passage" (⌘K), "add to notes"
/// and "highlight" (⇧⌘H) act on the notes editor and the book selection; back/forward (⌘[ ⌘])
/// follow whichever pane has focus. Enabled state comes from the models, so a disabled command
/// explains itself.
@MainActor @Observable
public final class WindowCommands {
    @ObservationIgnored weak var app: AppModel?
    /// Which pane takes ⌘[ / ⌘]: the notes editor's focus state, else the reader.
    public internal(set) var notesFocused = false
    /// The quick switcher's sheet (File › open quickly…, ⇧⌘O).
    public internal(set) var showsSwitcher = false

    public init() {}

    public func bind(_ app: AppModel) {
        self.app = app
    }

    /// File › open quickly…: opens the switcher sheet over the window.
    public func openQuickly() {
        showsSwitcher = true
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

    /// Format › highlight (⇧⌘H, Books' shortcut): the book's selection, in the colour last picked.
    public func highlightSelection() {
        guard let reader = app?.reader else { return }
        Task { _ = try? await reader.highlightSelection() }
    }

    /// Into the editor at the caret when it shows the book's page, else straight to the page.
    public func addToNotes() async {
        guard let app else { return }
        if let edit = try? await app.addReaderSelectionToNotes() { editor?.apply(edit) }
    }

    // MARK: Find

    /// Find… (⌘F): opens the toolbar search with the default scope for where the user is.
    public func find() {
        app?.search.present()
        app?.search.resetToDefaultScope()  // the brief: ⌘F means the default scope for here
    }

    public var canStepSearch: Bool { app?.search.stepper.count ?? 0 > 0 }

    /// Find Next/Previous (⌘G, ⇧⌘G), through the results with wraparound.
    public func stepSearch(forward: Bool) {
        guard let app else { return }
        Task { await app.stepSearch(by: forward ? 1 : -1) }
    }

    // MARK: Layout

    public var layout: SplitLayout {
        get { app?.workspace.layout ?? .split }
        set { app?.workspace.layout = newValue }
    }

    // MARK: Sidebar

    /// Whether the window's sidebar is docked; the window owns the choice and keeps this current.
    public internal(set) var sidebarDocked = true
    @ObservationIgnored var toggleSidebarDocking: (() -> Void)?

    /// View › show/hide sidebar (⌃⌘S): docks or undocks it, like the toolbar's sidebar button.
    public func toggleSidebar() {
        toggleSidebarDocking?()
    }

    // MARK: History

    private var paneCanGoBack: Bool { notesFocused ? (app?.workspace.canGoBackInNotes ?? false) : (app?.workspace.canGoBackInReader ?? false) }
    private var paneCanGoForward: Bool { notesFocused ? (app?.workspace.canGoForwardInNotes ?? false) : (app?.workspace.canGoForwardInReader ?? false) }
    /// While the search shows, back leaves it (the field folds away, the previous view returns)
    /// and forward has nowhere to go. At the start of a book's trail, back leaves for the
    /// library, and forward comes back.
    private var searching: Bool { app?.search.showsResults == true }
    public var canGoBack: Bool { searching || paneCanGoBack || app?.workspace.canGoHome == true }
    public var canGoForward: Bool { !searching && (paneCanGoForward || app?.workspace.canReturnToBook == true) }

    public func goBack() {
        guard let app else { return }
        if searching { Task { await app.endSearch() }; return }
        if !paneCanGoBack { app.workspace.goHome(); return }
        Task {
            if notesFocused { try? await app.workspace.goBackInNotes() } else { try? await app.workspace.goBackInReader() }
        }
    }

    public func goForward() {
        guard let app, !searching else { return }
        if app.workspace.canReturnToBook { app.workspace.returnToBook(); return }
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
        CommandGroup(after: .newItem) {
            Button("open quickly…") { commands?.openQuickly() }
                .keyboardShortcut("o", modifiers: [.shift, .command])
                .disabled(commands == nil)
        }
        // The system's sidebar item and shortcut (⌃⌘S), for gloss's own sidebar: there is no split
        // view for the system's to act on.
        CommandGroup(replacing: .sidebar) {
            Button(commands?.sidebarDocked == false ? "show sidebar" : "hide sidebar") { commands?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(commands == nil)
        }
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
        // Edit ▸ Find, after the system's text-editing group; ⌘F/⌘G/⇧⌘G are the system's find
        // shortcuts, not ones gloss is taking.
        CommandGroup(after: .textEditing) {
            Button("find…") { commands?.find() }
                .keyboardShortcut("f", modifiers: [.command])
            Button("find next") { commands?.stepSearch(forward: true) }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(commands?.canStepSearch != true)
                .help("the next result, wrapping around")
            Button("find previous") { commands?.stepSearch(forward: false) }
                .keyboardShortcut("g", modifiers: [.shift, .command])
                .disabled(commands?.canStepSearch != true)
                .help("the previous result, wrapping around")
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
            Button("highlight") { commands?.highlightSelection() }
                .keyboardShortcut("h", modifiers: [.shift, .command])
                .disabled(commands?.canQuote != true)
                .help("the book's selection, in the colour you used last")
        }
    }
}

extension GlossWindowCommands {
    /// The View menu's layout items, Preview-style ⌥⌘ numbers.
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
