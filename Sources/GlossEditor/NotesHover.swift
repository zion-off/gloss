import AppKit
import SwiftUI
import GlossCore
import GlossNotes

/// The popover that appears when the pointer rests on a `gloss://passage/…` link in the notes:
/// the passage's quote, its label and its book. Transient, so any click elsewhere dismisses it.
@MainActor
final class NotesHoverPopover {
    private let popover = NSPopover()
    private var hoveredLink: LinkTargetID?

    init() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: AnyView(EmptyView()))
    }

    /// Shows the preview for `preview` anchored to `rect` (in the text view's coordinates), or
    /// closes when `preview` is nil. The same target twice in a row does nothing.
    func show(_ preview: PassagePreview?, for target: LinkTargetID?, of view: NSView, anchor: NSRect) {
        guard let preview, let target else {
            hoveredLink = nil
            if popover.isShown { popover.close() }
            return
        }
        guard target != hoveredLink else { return }
        hoveredLink = target
        popover.contentViewController = NSHostingController(rootView: AnyView(PassagePreviewView(preview: preview)))
        if popover.isShown {
            popover.close()
        }
        popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    }

    func close() {
        hoveredLink = nil
        if popover.isShown { popover.close() }
    }
}

/// What the hover shows: the quote, where it sits, which book.
struct PassagePreviewView: View {
    let preview: PassagePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: preview.quote)
                .font(.callout)
                .lineLimit(4)
                .frame(maxWidth: 260, alignment: .leading)
            Text(verbatim: "\(preview.documentTitle)\(preview.label.map { " · \($0)" } ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
    }
}
