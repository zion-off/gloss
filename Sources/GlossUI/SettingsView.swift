#if os(macOS)
import Foundation
import SwiftUI
import GlossAppModel
import GlossCore
import GlossReaderBridge

/// The Settings window (⌘,): one form with a "general" and a "reading" part, Safari-style.
/// Tabs are the other Apple pattern, but the only tab API a macOS 14 target can use
/// (`tabItem`) is deprecated in the newest SDK, and its replacement needs macOS 15 (D-121).
public struct GlossSettingsView: View {
    @Bindable var model: AppSettingsModel

    public init(model: AppSettingsModel) {
        _model = Bindable(wrappedValue: model)
    }

    public var body: some View {
        Form {
            Section("general") {
                Picker("keep trashed things", selection: retention) {
                    ForEach(AppSettingsModel.retentionChoices, id: \.self) { choice in
                        Text(verbatim: Self.retentionLabel(choice)).tag(choice)
                    }
                }
            }
            Section("reading") {
                Picker("theme", selection: $model.reader.theme) {
                    ForEach(ReaderSettings.Theme.allCases, id: \.self) { theme in
                        Text(verbatim: theme.rawValue).tag(theme)
                    }
                }
                LabeledContent("text size") {
                    HStack {
                        Text(verbatim: "\(Int(model.reader.fontSize))")
                        Slider(value: $model.reader.fontSize, in: 12...24, step: 1) { Text("text size") }
                    }
                }
                LabeledContent("line spacing") {
                    HStack {
                        Text(verbatim: String(format: "%.1f", model.reader.lineHeight))
                        Slider(value: $model.reader.lineHeight, in: 1.2...2.0, step: 0.1) { Text("line spacing") }
                    }
                }
                LabeledContent("margins") {
                    HStack {
                        Text(verbatim: "\(model.reader.margin)")
                        Slider(value: margin, in: 16...96, step: 8) { Text("margins") }
                    }
                }
                Picker("flow", selection: $model.reader.flow) {
                    Text("pages").tag(ReaderFlow.paginated)
                    Text("scrolling").tag(ReaderFlow.scrolled)
                }
                Picker("columns", selection: $model.reader.maxColumnCount) {
                    Text("one").tag(1)
                    Text("two").tag(2)
                }
            }
        }
        .frame(width: 420)
        .task { await model.load() }
        // A save that didn't store says so here rather than pretending it landed (review 7).
        .overlay(alignment: .bottom) {
            if let problem = model.saveProblem {
                Text(verbatim: problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
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
#endif
