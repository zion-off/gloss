#if os(macOS)
import Foundation
import SwiftUI
import GlossCore
import GlossAppModel

extension HighlightColor {
    /// The system colour for this highlight's swatch, so it follows light and dark mode like the
    /// rest of the UI (the reader's popover and the source list share it).
    public var swatch: Color {
        switch self {
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .pink: .pink
        case .purple: .purple
        }
    }
}

extension ReaderController {
    /// Removes a highlight, undoable from Edit › Undo through `undo` (the window's undo manager).
    /// The popover's "remove highlight" and the source list's delete both come here.
    public func removeHighlight(_ highlight: Highlight, undo: UndoManager?) {
        Task {
            guard let removed = try? await deleteHighlight(highlight.id) else { return }
            undo?.registerUndo(withTarget: self) { reader in
                Task { try? await reader.restoreHighlight(removed) }
            }
            undo?.setActionName("remove highlight")
        }
    }
}
#endif
