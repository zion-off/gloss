import SwiftUI
import GlossAppModel
import GlossCore

/// "open quickly" (⇧⌘O): a small sheet over the window, one field, up/down/return to
/// open, escape to close — after Xcode's switcher. The list and the debounced search live in
/// the portable `QuickSwitcherModel`; this is only the presentation.
struct QuickSwitcherSheet: View {
    let app: AppModel
    @Binding var isPresented: Bool
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("jump to a book or page", text: Binding(
                get: { app.switcher.query },
                set: { app.switcher.query = $0 }))
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onKeyPress(keys: [.upArrow, .downArrow, .return]) { press in
                    switch press.key {
                    case .upArrow:
                        app.switcher.moveSelection(by: -1)
                    case .downArrow:
                        app.switcher.moveSelection(by: 1)
                    case .return:
                        openSelected()
                    default:
                        return .ignored
                    }
                    return .handled
                }
            Divider()
            list
        }
        .frame(width: 420, height: 320)
        .background(.regularMaterial)
        .onAppear {
            fieldFocused = true
            app.switcher.reset()
        }
    }

    @ViewBuilder private var list: some View {
        if app.switcher.items.isEmpty {
            VStack {
                ContentUnavailableView("nothing yet", systemImage: "sparkle.magnifyingglass",
                                       description: Text("type a word from a title or a note"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(app.switcher.items.enumerated()), id: \.element.id) { index, item in
                        QuickSwitcherRow(item: item, selected: index == app.switcher.selectedIndex)
                            .contentShape(Rectangle())
                            .onTapGesture { open(item) }
                    }
                }
                .padding(6)
            }
        }
    }

    private func openSelected() {
        guard let item = app.switcher.selected else { return }
        open(item)
    }

    private func open(_ item: QuickSwitcherModel.Item) {
        isPresented = false
        Task {
            await app.open(item)
        }
    }
}

/// One row: a book or a page, its book underneath, the keyboard's pick highlighted.
struct QuickSwitcherRow: View {
    let item: QuickSwitcherModel.Item
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isPage ? "doc.text" : "book")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title).lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(Color.clear))
        .cornerRadius(6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(item.isPage ? "page" : "book"): \(item.title)"))
    }
}

/// The sheet the File menu's "open quickly…" opens; MainWindow attaches it in one line.
extension View {
    public func quickSwitcher(app: AppModel, isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            QuickSwitcherSheet(app: app, isPresented: isPresented)
        }
    }
}
