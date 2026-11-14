import AppKit
import SwiftUI
import GlossAppModel
import GlossCore
import GlossNotes

/// The notes pane: the model's text in a TextKit 2 view, with the floating format bar and
/// slash menu over it and a note when a save failed.
public struct NotesEditor: View {
    let model: NotesEditorModel
    let reveal: NotesReveal?
    let onOpenGlossLink: @MainActor (GlossLink) async -> Void
    let onOpenWebLink: @MainActor (URL) -> Void
    let onOpenPage: @MainActor (PageID) -> Void

    @State private var actions = NotesEditorActions()
    @State private var selectionRect: OverlayRect?
    @State private var slashAnchor: SlashAnchor?

    let onActionsReady: @MainActor (NotesEditorActions) -> Void

    /// - Parameter actions: receives the editor's actions once it's on screen (the window wires
    ///   ⌘K, add to notes and focus-routed history through them).
    public init(model: NotesEditorModel, reveal: NotesReveal?,
                onOpenGlossLink: @escaping @MainActor (GlossLink) async -> Void,
                onOpenWebLink: @escaping @MainActor (URL) -> Void,
                onOpenPage: @escaping @MainActor (PageID) -> Void,
                actions onActionsReady: @escaping @MainActor (NotesEditorActions) -> Void = { _ in }) {
        self.model = model
        self.reveal = reveal
        self.onOpenGlossLink = onOpenGlossLink
        self.onOpenWebLink = onOpenWebLink
        self.onOpenPage = onOpenPage
        self.onActionsReady = onActionsReady
    }

    public var body: some View {
        GeometryReader { geometry in
            NotesEditorRepresentable(model: model, actions: actions, reveal: reveal,
                                     onOpenGlossLink: onOpenGlossLink,
                                     onOpenWebLink: onOpenWebLink,
                                     onOpenPage: onOpenPage,
                                     selectionRectChanged: { selectionRect = $0 },
                                     slashAnchorChanged: { slashAnchor = $0 })
                .overlay(alignment: .topLeading) { overlays(in: geometry.size) }
        }
        .focusedSceneValue(\.notesEditorActions, actions)
        .onAppear { onActionsReady(actions) }
    }

    /// Where the format bar goes, or nil when it's hidden.
    private var formatBarAnchor: OverlayRect? {
        FormatBar.shouldShow(selection: model.selection, subpageRows: model.subpageRows) ? selectionRect : nil
    }

    @ViewBuilder private func overlays(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let rect = formatBarAnchor {
                // Position by top edge: the bar sits over the selection when there's room, under
                // it when there isn't.
                FormatBarHost(model: model, actions: actions)
                    .position(x: OverlayGeometry.clampCenter(rect.midX, width: FormatBarView.width, in: size.width),
                              y: OverlayGeometry.above(anchor: rect, height: FormatBarView.height) + FormatBarView.height / 2)
            }
        }
        // No transition, like the slash menu: the bar is there when the selection is, and moves
        // with it at once.
        // Hangs from its slash and follows it as the note scrolls. Once the slash's line is out
        // of view the menu hides until it's back; it stays open meanwhile (typing scrolls the
        // caret back into view, Escape closes it).
        if let menu = model.slashMenu, let anchor = slashAnchor, anchor.offset == menu.trigger.range.lowerBound,
           anchor.rect.maxY > 0, anchor.rect.minY < size.height {
            SlashMenuLayout(anchor: anchor.rect) {
                SlashMenuRows(menu: menu, confirm: { _ in })
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                SlashMenuHost(menu: SlashMenuView(menu: menu, confirm: { id in Task { await actions.confirmSlash(id) } }))
            }
            // A new slash is a new menu: it decides its side afresh.
            .id(menu.trigger.range.lowerBound)
        }
    }
}

/// Places the slash menu by its slash, inside the editor: measures the rows (the hidden first
/// subview) at the menu's width, asks `OverlayGeometry` where a menu that tall goes, and gives
/// the menu (the second) that frame. All in one layout pass, so a menu that opens or shrinks is
/// placed right in the frame it first draws in.
///
/// The side, once taken, holds until the slash or the room around it moves (the cache outlives
/// updates; `.id` resets it per menu), so a list shrinking or growing as it's filtered doesn't
/// jump across the line.
private struct SlashMenuLayout: Layout {
    let anchor: OverlayRect

    struct Side {
        var anchor: OverlayRect
        var available: OverlayRect
        var flipped: Bool
    }

    func makeCache(subviews: Subviews) -> Side? { nil }

    func updateCache(_ cache: inout Side?, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Side?) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Side?) {
        guard subviews.count == 2 else { return }
        let rows = subviews[0].sizeThatFits(ProposedViewSize(width: SlashMenuView.width, height: nil))
        let size = OverlaySize(width: SlashMenuView.width, height: min(rows.height, SlashMenuView.maxHeight))
        let available = OverlayRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        let kept = cache.flatMap { $0.anchor == anchor && $0.available == available ? $0.flipped : nil }
        let placement = OverlayGeometry.menuPlacement(anchor: anchor, size: size, in: available, keepingFlipped: kept)
        cache = Side(anchor: anchor, available: available, flipped: placement.flipped)
        subviews[0].place(at: bounds.origin, proposal: .zero)
        let frame = placement.frame
        subviews[1].place(at: CGPoint(x: bounds.minX + frame.x, y: bounds.minY + frame.y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
    }
}

/// The format bar: the standard buttons, in a system material, floating over the selection.
struct FormatBarView: View {
    /// One button's cell: the whole cell takes the click, the hover fill sits inside it.
    static let cell = CGSize(width: 28, height: 24)
    static let width: CGFloat = CGFloat(FormatBar.items.count) * cell.width + 12
    static let height: CGFloat = 32

    let model: NotesEditorModel
    let actions: NotesEditorActions

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FormatBar.items) { item in
                let isActive = model.activeFormats.contains(item.id)
                Button {
                    actions.run(item)
                } label: {
                    Image(systemName: item.symbol)
                }
                .buttonStyle(FormatBarButtonStyle(isActive: isActive))
                .help(Text(verbatim: "\(item.title) (\(item.shortcutLabel))"))
                .accessibilityLabel(Text(item.title))
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(width: Self.width, height: Self.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 2, y: 1)
    }
}

/// A format bar button the way toolbar buttons behave: a soft rounded fill fades in under the
/// pointer (the subpage rows' hover colour), deepens while pressed, and the glyph takes the
/// accent colour when the format is on.
private struct FormatBarButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        Cell(configuration: configuration, isActive: isActive)
    }

    private struct Cell: View {
        let configuration: Configuration
        let isActive: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary))
                .frame(width: FormatBarView.cell.width, height: FormatBarView.cell.height)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(fill)
                        .padding(.horizontal, 1)
                        .animation(.easeOut(duration: 0.12), value: isHovered)
                }
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return Color(nsColor: .tertiaryLabelColor) }
            return isHovered ? Color(nsColor: .quaternaryLabelColor) : .clear
        }
    }
}

/// Hosts the format bar in a view of its own over the text, so the bar owns the pointer.
///
/// The text view's I-beam is a cursor rect over its whole visible area, and AppKit doesn't
/// clip cursor rects or tracking areas by what's drawn on top. Drawn by the editor's own
/// hosting view, the bar had no view of its own to claim the cursor: the I-beam showed through,
/// the arrow set on each hover move lost to every cursor-rect reset (each edit lays the text out
/// again), and leaving the bar left the arrow over the text. A cursor-update area of its own
/// makes AppKit send the cursor update to the bar when the pointer comes in, and to the text
/// view (its I-beam) when it goes back out.
private struct FormatBarHost: NSViewRepresentable {
    let model: NotesEditorModel
    let actions: NotesEditorActions

    func makeNSView(context: Context) -> FloatingHostingView<FormatBarView> {
        let view = FloatingHostingView(rootView: FormatBarView(model: model, actions: actions))
        view.clipsToBounds = false  // the bar's shadow falls outside its frame
        return view
    }

    func updateNSView(_ nsView: FloatingHostingView<FormatBarView>, context: Context) {
        nsView.rootView = FormatBarView(model: model, actions: actions)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FloatingHostingView<FormatBarView>, context: Context) -> CGSize? {
        CGSize(width: FormatBarView.width, height: FormatBarView.height)
    }
}

/// Hosts the slash menu in a view of its own, for the same reasons as the format bar: the arrow
/// over the whole menu, the I-beam back on the way out, and nothing in the text under it
/// reacting to the pointer. Sized by its placement.
private struct SlashMenuHost: NSViewRepresentable {
    let menu: SlashMenuView

    func makeNSView(context: Context) -> FloatingHostingView<SlashMenuView> {
        let view = FloatingHostingView(rootView: menu)
        view.clipsToBounds = false  // the menu's shadow falls outside its frame
        view.sizingOptions = []  // its frame comes from the placement, not from its content
        return view
    }

    func updateNSView(_ nsView: FloatingHostingView<SlashMenuView>, context: Context) {
        nsView.rootView = menu
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FloatingHostingView<SlashMenuView>, context: Context) -> CGSize? {
        CGSize(width: SlashMenuView.width, height: proposal.height ?? SlashMenuView.maxHeight)
    }
}

/// A floating control's own hosting view over the text: it owns the pointer where it's drawn.
private final class FloatingHostingView<Content: View>: NSHostingView<Content> {
    private var cursorArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorArea { removeTrackingArea(cursorArea) }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorArea = area
    }

    /// The arrow over the whole control, buttons and gaps alike, like any toolbar, palette or menu.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    /// A click on a button leaves the keyboard focus, and so the selection, in the text.
    override var acceptsFirstResponder: Bool { false }
}

/// The slash menu: its rows in a system material, scrolling past its height.
struct SlashMenuView: View {
    // Nonisolated: the layout that places the menu reads them.
    nonisolated static let width: CGFloat = 260
    /// The tallest it gets; a longer list scrolls.
    nonisolated static let maxHeight: CGFloat = 250

    let menu: NotesEditorModel.SlashMenu
    let confirm: (String?) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                SlashMenuRows(menu: menu, confirm: confirm)
            }
            // A menu cut short by the room it has keeps the row the arrow keys reach in view.
            .onChange(of: menu.selectedIndex) { _, index in
                if menu.items.indices.contains(index) { proxy.scrollTo(menu.items[index].id) }
            }
        }
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1) }
        .shadow(radius: 4, y: 2)
        .accessibilityLabel(Text("insert menu"))
    }
}

/// The menu's items, the selected row highlighted, clicks run.
struct SlashMenuRows: View {
    let menu: NotesEditorModel.SlashMenu
    let confirm: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
                Button {
                    confirm(item.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: item.title)
                            if !item.subtitle.isEmpty {
                                Text(verbatim: item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(item.id)
                .background(index == menu.selectedIndex ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(Color.clear))
                .accessibilityLabel(Text(verbatim: "\(item.title), \(item.subtitle)"))
            }
        }
        .padding(4)
        // Pinned: the menu's height is measured from a copy of these rows outside its own
        // hosting view, and both must lay out alike.
        .font(.body)
    }
}

/// The representable that owns the coordinator.
struct NotesEditorRepresentable: NSViewRepresentable {
    let model: NotesEditorModel
    let actions: NotesEditorActions
    let reveal: NotesReveal?
    let onOpenGlossLink: @MainActor (GlossLink) async -> Void
    let onOpenWebLink: @MainActor (URL) -> Void
    let onOpenPage: @MainActor (PageID) -> Void
    let selectionRectChanged: (OverlayRect?) -> Void
    let slashAnchorChanged: (SlashAnchor?) -> Void

    func makeCoordinator() -> NotesEditorCoordinator {
        let coordinator = NotesEditorCoordinator(model: model, actions: actions)
        coordinator.openGlossLink = onOpenGlossLink
        coordinator.openWebLink = onOpenWebLink
        coordinator.openPage = onOpenPage
        coordinator.selectionRectChanged = selectionRectChanged
        coordinator.slashAnchorChanged = slashAnchorChanged
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Rewired every update: the closures capture this view's values, which a future caller
        // could change between renders.
        context.coordinator.openGlossLink = onOpenGlossLink
        context.coordinator.openWebLink = onOpenWebLink
        context.coordinator.openPage = onOpenPage
        context.coordinator.sync(reveal: reveal)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: NotesEditorCoordinator) {
        coordinator.dismantle()
    }
}
