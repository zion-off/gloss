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
    let onOpenGlossLink: @MainActor (GlossLink) async -> Void
    let onOpenWebLink: @MainActor (URL) -> Void
    let onOpenPage: @MainActor (PageID) -> Void

    @State private var selectionRect: NSRect?
    @State private var caretRect: NSRect?

    public init(model: NotesEditorModel,
                onOpenGlossLink: @escaping @MainActor (GlossLink) async -> Void,
                onOpenWebLink: @escaping @MainActor (URL) -> Void,
                onOpenPage: @escaping @MainActor (PageID) -> Void) {
        self.model = model
        self.onOpenGlossLink = onOpenGlossLink
        self.onOpenWebLink = onOpenWebLink
        self.onOpenPage = onOpenPage
    }

    public var body: some View {
        NotesEditorRepresentable(model: model,
                                 onOpenGlossLink: onOpenGlossLink,
                                 onOpenWebLink: onOpenWebLink,
                                 onOpenPage: onOpenPage,
                                 selectionRectChanged: { selectionRect = $0 },
                                 caretRectChanged: { caretRect = $0 })
            .overlay(alignment: .topLeading) { overlays }
    }

    @ViewBuilder private var overlays: some View {
        if FormatBar.shouldShow(selection: model.selection, subpageRows: model.subpageRows),
           let rect = selectionRect {
            FormatBarView(model: model, apply: apply)
                .position(x: rect.midX, y: rect.minY - 26)
        }
        if let menu = model.slashMenu, let rect = caretRect {
            SlashMenuView(model: model, confirm: { Task { await confirm($0) } })
                .position(x: min(max(rect.midX, SlashMenuView.width / 2 + 8), caretRectBoundary),
                          y: rect.maxY + SlashMenuView.height / 2 + 6)
                .id(menu.trigger.range.lowerBound)
                .allowsHitTesting(true)
                .accessibilityLabel(Text("insert menu"))
        }
    }

    private var caretRectBoundary: CGFloat {
        // Keep the menu inside the editor's width; SwiftUI gives no geometry here, so anchor
        // it to the caret and let the Mac check catch overflow (handoff).
        caretRect.map { $0.maxX + SlashMenuView.width } ?? SlashMenuView.width
    }

    private func apply(_ result: EditResult?) {
        guard let result else { return }
        // The coordinator's apply is reached through the representable's context; the format
        // bar goes through the model's command, which the view applies on its next sync.
        model.applyExternally(result)
    }

    private func confirm(_ itemID: String?) async {
        await model.confirmSlashExternally(itemID: itemID)
    }
}

/// The format bar: the standard buttons, in a system material, floating over the selection.
struct FormatBarView: View {
    let model: NotesEditorModel
    let apply: (EditResult?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FormatBar.items) { item in
                Button {
                    apply(model.run(item.command))
                } label: {
                    Image(systemName: item.symbol)
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.borderless)
                .help(item.title)
                .foregroundStyle(model.activeFormats.contains(item.id) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary))
                .accessibilityLabel(Text(item.title))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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
    let onOpenGlossLink: @MainActor (GlossLink) async -> Void
    let onOpenWebLink: @MainActor (URL) -> Void
    let onOpenPage: @MainActor (PageID) -> Void
    let selectionRectChanged: (NSRect?) -> Void
    let caretRectChanged: (NSRect?) -> Void

    func makeCoordinator() -> NotesEditorCoordinator {
        let coordinator = NotesEditorCoordinator(model: model)
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
        context.coordinator.sync(reveal: nil)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: NotesEditorCoordinator) {
        coordinator.dismantle()
    }
}
#endif
