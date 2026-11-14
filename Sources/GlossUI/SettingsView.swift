import AppKit
import Foundation
import SwiftUI
import GlossAppModel
import GlossCore
import GlossReaderBridge

/// The Settings window (⌘,): one grouped form like System Settings, "reading" first (it is what
/// people come here for), then "trash". Tabs are the other Apple pattern, but the only tab API a
/// macOS 14 target can use (`tabItem`) is deprecated in the newest SDK, and its replacement needs
/// macOS 15. A sample page at the top shows the reading settings as they change; open
/// books take them once, when the window closes.
public struct GlossSettingsView: View {
    @Bindable var model: AppSettingsModel

    public init(model: AppSettingsModel) {
        _model = Bindable(wrappedValue: model)
    }

    public var body: some View {
        Form {
            Section("reading") {
                ReadingSample(settings: model.reader)
                Picker("theme", selection: $model.reader.theme) {
                    ForEach(ReaderSettings.Theme.allCases, id: \.self) { theme in
                        Text(verbatim: theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                ValueSlider("text size", value: $model.reader.fontSize, in: 12...24, step: 1,
                            shown: "\(Int(model.reader.fontSize)) pt")
                ValueSlider("line spacing", value: $model.reader.lineHeight, in: 1.2...2.0, step: 0.1,
                            shown: String(format: "%.1f", model.reader.lineHeight))
                ValueSlider("margins", value: margin, in: 16...96, step: 8, shown: "\(model.reader.margin) pt")
                Picker("layout", selection: $model.reader.flow) {
                    Text("pages").tag(ReaderFlow.paginated)
                    Text("scrolling").tag(ReaderFlow.scrolled)
                }
                .pickerStyle(.segmented)
                // Columns only exist between page turns; a scrolling book is one column.
                Picker("columns", selection: $model.reader.maxColumnCount) {
                    Text("one").tag(1)
                    Text("two").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(model.reader.flow == .scrolled)
            }
            Section {
                Picker("keep trashed things", selection: retention) {
                    ForEach(AppSettingsModel.retentionChoices, id: \.self) { choice in
                        Text(verbatim: Self.retentionLabel(choice)).tag(choice)
                    }
                }
            } header: {
                Text("trash")
            } footer: {
                // A save that didn't store says so here rather than pretending it landed.
                if let problem = model.saveProblem {
                    Text(verbatim: problem)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.load() }
        // Closing the window is when open books change: store what's pending, then announce it.
        .onDisappear { Task { await model.flushSave() } }
    }

    /// The picker edits the model's choice directly; the save is the model's didSet.
    private var retention: Binding<Int?> {
        Binding(get: { model.retentionDays }, set: { model.retentionDays = $0 })
    }

    /// Margins are an Int in the settings; the slider is a Double.
    private var margin: Binding<Double> {
        Binding(get: { Double(model.reader.margin) },
                set: { model.reader.margin = Int($0) })
    }

    /// "for 7 days" … "forever".
    static func retentionLabel(_ choice: Int?) -> String {
        switch choice {
        case .some(let days): "for \(days) days"
        case nil: "forever"
        }
    }
}

/// A form row: the label on the left, the slider and its current value on the right. The value
/// has a fixed width so the slider doesn't shift while it changes.
private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let step: Double
    let shown: String

    init(_ title: String, value: Binding<Double>, in bounds: ClosedRange<Double>, step: Double, shown: String) {
        self.title = title
        _value = value
        self.bounds = bounds
        self.step = step
        self.shown = shown
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: bounds, step: step) { Text(verbatim: title) }
                    .labelsHidden()
                Text(verbatim: shown)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

/// A page of the book as it will look: the theme's colours, the reader's font at the chosen size
/// and spacing, the margins (at half scale, so the page still fits) and one or two columns. It
/// reads the model's values as they are edited, so every drag shows at once.
private struct ReadingSample: View {
    let settings: ReaderSettings

    private static let passages = [
        "it was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness, it was the epoch of belief, it was the epoch of incredulity, it was the season of light, it was the season of darkness.",
        "it was the spring of hope, it was the winter of despair, we had everything before us, we had nothing before us, we were all going direct to heaven, we were all going direct the other way.",
    ]
    /// Margins are shown at this scale: at full size a 96 pt margin would leave no page.
    private static let marginScale = 0.5
    private static let height: CGFloat = 200

    var body: some View {
        let colors = AppearanceStyler().appearance(for: settings).colors
        let foreground = Self.color(colors.foreground, fallback: .labelColor)
        let twoColumns = settings.flow == .paginated && settings.maxColumnCount > 1
        GeometryReader { proxy in
            // The reader's gap between columns is 6% of the page (AppearanceStyler's layout).
            let gap = proxy.size.width * 0.06
            HStack(alignment: .top, spacing: gap) {
                column(Self.passages[0] + (twoColumns ? "" : " " + Self.passages[1]))
                if twoColumns { column(Self.passages[1]) }
            }
            .foregroundStyle(foreground)
            .padding(.vertical, CGFloat(settings.margin) * Self.marginScale)
            .padding(.horizontal, gap / 2 + 8)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(height: Self.height)
        .background(Self.color(colors.background, fallback: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("sample page in the \(settings.theme.rawValue) theme")
    }

    /// One column of text in the reader's font: `-apple-system` (the system font) at the text
    /// size, with CSS line-height approximated as extra spacing over the font's own (~1.2×).
    private func column(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: settings.fontSize))
            .lineSpacing(max(0, settings.lineHeight - 1.2) * settings.fontSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
    }

    static func color(_ css: String, fallback: NSColor) -> Color {
        guard let color = CSSColor(hex: css) else { return Color(nsColor: fallback) }
        return Color(nsColor: NSColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green),
                                      blue: CGFloat(color.blue), alpha: CGFloat(color.alpha)))
    }
}
