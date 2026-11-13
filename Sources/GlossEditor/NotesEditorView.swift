#if os(macOS)
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
    @State private var caretRect: OverlayRect?

    public init(model: NotesEditorModel, reveal: NotesReveal?,
                onOpenGlossLink: @escaping @MainActor (GlossLink) async -> Void,
                onOpenWebLink: @escaping @MainActor (URL) -> Void,
                onOpenPage: @escaping @MainActor (PageID) -> Void) {
        self.model = model
        self.reveal = reveal
        self.onOpenGlossLink = onOpenGlossLink
        self.onOpenWebLink = onOpenWebLink
        self.onOpenPage = onOpenPage
    }

    public var body: some View {
        GeometryReader { geometry in
            NotesEditorRepresentable(model: model, actions: actions, reveal: reveal,
                                     onOpenGlossLink: onOpenGlossLink,
                                     onOpenWebLink: onOpenWebLink,
                                     onOpenPage: onOpenPage,
                                     selectionRectChanged: { selectionRect = $0 },
                                     caretRectChanged: { caretRect = $0 })
                .overlay(alignment: .topLeading) { overlays(in: geometry.size) }
        }
        .focusedSceneValue(\.notesEditorActions, actions)
    }

    @ViewBuilder private func overlays(in size: CGSize) -> some View {
        if FormatBar.shouldShow(selection: model.selection, subpageRows: model.subpageRows),
           let rect = selectionRect {
            // Position by top edge: the bar sits over the selection when there's room, under
            // it when there isn't.
            FormatBarView(model: model, actions: actions)
                .position(x: OverlayGeometry.clampCenter(rect.midX, width: FormatBarView.width, in: size.width),
                          y: OverlayGeometry.above(anchor: rect, height: FormatBarView.height) + FormatBarView.height / 2)
        }
        if let menu = model.slashMenu, let rect = caretRect {
            SlashMenuView(model: model, confirm: { id in Task { await actions.confirmSlash(id) } })
                .position(x: OverlayGeometry.clampCenter(rect.minX + SlashMenuView.width / 2, width: SlashMenuView.width, in: size.width),
                          y: OverlayGeometry.belowCenter(anchor: rect, height: SlashMenuView.height))
                .id(menu.trigger.range.lowerBound)
                .accessibilityLabel(Text("insert menu"))
        }
    }
}

/// The format bar: the standard buttons, in a system material, floating over the selection.
struct FormatBarView: View {
    static let width: CGFloat = CGFloat(FormatBar.items.count) * 28 + 12
    static let height: CGFloat = 32

    let model: NotesEditorModel
    let actions: NotesEditorActions

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FormatBar.items) { item in
                Button {
                    actions.run(item)
                } label: {
                    Image(systemName: item.symbol)
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.borderless)
                .help("\(item.title) (\(item.shortcutLabel))")
                .foregroundStyle(model.activeFormats.contains(item.id) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary))
                .accessibilityLabel(Text(item.title))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(height: Self.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 2, y: 1)
    }
}

/// The slash menu: the model's items, the selected row highlighted, clicks run.
struct SlashMenuView: View {
    static let width: CGFloat = 260
    static let height: CGFloat = 250

    let model: NotesEditorModel
    let confirm: (String?) -> Void

    var body: some View {
        if let menu = model.slashMenu {
            ScrollView {
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
                        .background(index == menu.selectedIndex ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(Color.clear))
                        .accessibilityLabel(Text("\(item.title), \(item.subtitle)"))
                    }
                }
                .padding(4)
            }
            .frame(width: Self.width, maxHeight: Self.height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.separatorColor, lineWidth: 1))
            .shadow(radius: 4, y: 2)
        }
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
    let selectionRectChanged: (NSRect?) -> Void
    let caretRectChanged: (NSRect?) -> Void

    func makeCoordinator() -> NotesEditorCoordinator {
        let coordinator = NotesEditorCoordinator(model: model, actions: actions)
        coordinator.openGlossLink = onOpenGlossLink
        coordinator.openWebLink = onOpenWebLink
        coordinator.openPage = onOpenPage
        coordinator.selectionRectChanged = selectionRectChanged
        coordinator.caretRectChanged = caretRectChanged
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Rewired every update: the closures capture this view's values, which a future caller
        // could change between renders (review 5).
        context.coordinator.openGlossLink = onOpenGlossLink
        context.coordinator.openWebLink = onOpenWebLink
        context.coordinator.openPage = onOpenPage
        context.coordinator.sync(reveal: reveal)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: NotesEditorCoordinator) {
        coordinator.dismantle()
    }
}
#endif
