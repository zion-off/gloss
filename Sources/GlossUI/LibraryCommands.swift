#if os(macOS)
import SwiftUI
import GlossAppModel

/// File › import… — ⇧⌘A, Apple Books' "add to library" shortcut. The command reaches
/// the key window's library presentation state through a focused value, so the panel and its
/// import land in the window the menu acted on.
public struct LibraryCommands: Commands {
    @FocusedValue(\.libraryPresentation) private var presentation: LibraryPresentationModel?

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("import…") { presentation?.showsImportPanel = true }
                .keyboardShortcut("a", modifiers: [.shift, .command])
                .disabled(presentation == nil)
        }
    }
}

extension FocusedValues {
    /// The key window's library presentation state (its import panel and sheets).
    @Entry public var libraryPresentation: LibraryPresentationModel?
}
#endif
