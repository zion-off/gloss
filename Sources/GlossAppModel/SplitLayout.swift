import Foundation
import GlossCore

/// How the main window splits its panes. Global across windows (one setting).
public enum SplitLayout: String, Codable, CaseIterable, Sendable {
    case readerOnly
    case notesOnly
    case split

    public var showsReader: Bool { self != .notesOnly }
    public var showsNotes: Bool { self != .readerOnly }
}

public enum WorkspaceSettings {
    public static let layout = SettingKey<SplitLayout>("workspace.layout", default: .split)
}
