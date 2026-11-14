import AppKit
import SwiftUI

/// What sits above the notes' body and scrolls with it (the page's breadcrumbs and title): a
/// SwiftUI view hosted inside the text view, which keeps its text below it
/// (`NotesTextView.header`). Inside the scrolled view rather than above the scroll view, so it
/// scrolls away with the text the way a Notes or Notion title does.
@MainActor
final class NotesHeaderView: NSHostingView<AnyView> {
    /// Its content wants a different height (a title wrapping onto another line).
    var onSizeChange: (() -> Void)?
    /// The content's height at the width it was given, as it last reported it.
    private var reportedHeight: CGFloat?

    init(content: AnyView) {
        super.init(rootView: AnyView(EmptyView()))
        sizingOptions = []  // the text view frames it
        update(content: content)
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("not from a nib")
    }

    func update(content: AnyView) {
        // At its own height whatever it is offered, top-aligned, telling what that height is at
        // the width it has: a long title wraps.
        rootView = AnyView(content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
                self?.contentHeightChanged(ceil(height))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
    }

    /// How tall it is: as the content measures itself, or, before it has, its one-line height.
    var contentHeight: CGFloat {
        reportedHeight ?? ceil(fittingSize.height)
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height != reportedHeight else { return }
        reportedHeight = height
        onSizeChange?()
    }

    /// The arrow over the header's chrome (its title field still shows the I-beam): without a
    /// rect of its own, the text view's I-beam over its whole visible area showed through.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
