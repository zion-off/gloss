import SwiftUI
import GlossAppModel

/// The software update window's content, laid out like a system alert: the app's icon, a bold
/// title, the system's progress bar while something runs, a secondary line, the release notes in
/// a bordered text area, and push buttons along the bottom (an apart button at the far left,
/// cancel and the default button at the right). Each step replaces the last in place, with no
/// transition; the window fits itself to it.
public struct UpdateView: View {
    let flow: UpdateFlow

    public init(flow: UpdateFlow) {
        self.flow = flow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: flow.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    progress
                    if let detail = flow.detail {
                        Text(verbatim: detail)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notes = flow.notes {
                ReleaseNotesView(blocks: notes)
            }
            buttons
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder private var progress: some View {
        switch flow.progress {
        case .none:
            EmptyView()
        case .indeterminate:
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel(Text(verbatim: flow.title))
        case .fraction(let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .accessibilityLabel(Text(verbatim: flow.title))
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            ForEach(flow.actions.filter { $0.role == .leading }) { button($0) }
            Spacer(minLength: 0)
            ForEach(flow.actions.filter { $0.role == .cancel }) { button($0) }
            ForEach(flow.actions.filter { $0.role == .primary }) { button($0) }
        }
        // A step with nothing to press (getting ready) keeps the window's height steady.
        .frame(minHeight: 22)
    }

    private func button(_ action: UpdateFlow.Action) -> some View {
        Button { flow.perform(action) } label: {
            Text(verbatim: action.title).frame(minWidth: 64)
        }
        .keyboardShortcut(Self.shortcut(for: action.role))
    }

    private static func shortcut(for role: UpdateFlow.Action.Role) -> KeyboardShortcut? {
        switch role {
        case .primary: .defaultAction
        case .cancel: .cancelAction
        case .leading: nil
        }
    }
}

/// Release notes as text: headings, bulleted and numbered items with their wrapped lines hanging
/// past the marker, and paragraphs, each with its inline markdown (bold, links, code), in a
/// bordered, scrolling text area like a text view's.
struct ReleaseNotesView: View {
    let blocks: [ReleaseNotes.Block]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    switch block {
                    case .heading(let text):
                        Text(Self.inline(text))
                            .font(.headline)
                            .padding(.top, index == 0 ? 0 : 6)
                    case .paragraph(let text):
                        Text(Self.inline(text))
                    case .item(let marker, let text, let level):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: marker)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(minWidth: 14, alignment: .trailing)
                            Text(Self.inline(text))
                        }
                        .padding(.leading, CGFloat(level) * 20)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .textSelection(.enabled)
        }
        .frame(height: 220)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
    }

    static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}
