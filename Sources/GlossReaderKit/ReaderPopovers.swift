import SwiftUI
import GlossCore
import GlossAppModel
import GlossReaderBridge

/// What the reader's popover shows, by kind. Lowercase copy, system controls.
struct ReaderPopoverContent: View {
    let reader: ReaderController
    let addToNotes: @MainActor () async -> Void
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        switch reader.popover {
        case .selection?:
            selection
        case .highlight(let focus)?:
            highlight(focus)
        case .markerChoice(let choice)?:
            markerChoice(choice)
        case nil:
            EmptyView()
        }
    }

    // MARK: Selection: highlight it, or quote it into the notes

    private var selection: some View {
        VStack(alignment: .leading, spacing: 10) {
            colours(current: nil) { colour in
                Task { _ = try? await reader.highlightSelection(colour) }
            }
            Divider()
            Button("add to notes") { Task { await addToNotes() } }
                .buttonStyle(.borderless)
            Text("select words in your notes and press ⌘K to link them here")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 240)
    }

    // MARK: A clicked highlight: recolour, quote, remove

    private func highlight(_ focus: ReaderController.HighlightFocus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            colours(current: focus.highlight.color) { colour in
                Task { try? await reader.recolor(focus.highlight.id, to: colour) }
            }
            Divider()
            Button("remove highlight", role: .destructive) { reader.removeHighlight(focus.highlight, undo: undoManager) }
                .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 240)
    }

    // MARK: A marker linked from several notes: pick one

    private func markerChoice(_ choice: ReaderController.MarkerChoice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("linked from")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            ForEach(choice.references) { reference in
                Button {
                    Task { await reader.choose(reference.page) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: reference.page.title.isEmpty ? "untitled" : reference.page.title)
                        Text(verbatim: reference.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(reference.page.title): \(reference.snippet)"))
            }
        }
        .padding(.vertical, 8)
        .frame(width: 280)
    }

    // MARK: Colour row

    private func colours(current: HighlightColor?, pick: @escaping (HighlightColor) -> Void) -> some View {
        HStack(spacing: 10) {
            ForEach(HighlightColor.allCases, id: \.self) { colour in
                Button { pick(colour) } label: {
                    Circle()
                        .fill(colour.swatch)
                        .frame(width: 20, height: 20)
                        .overlay {
                            if colour == current {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.primary)
                            }
                        }
                }
                .buttonStyle(.plain)
                // Built from data, not a localization key: verbatim, so nothing in it is read as a
                // format specifier.
                .help(Text(verbatim: "\(colour.rawValue) highlight"))
                .accessibilityLabel(Text(verbatim: "\(colour.rawValue) highlight"))
                .accessibilityAddTraits(colour == current ? .isSelected : [])
            }
        }
    }
}
