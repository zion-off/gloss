#if os(macOS)
import AppKit
import SwiftUI
import GlossAppModel
import GlossCore

/// The "back up library…" flow: the save panel, then the copy (which runs off the
/// main actor, in the model), then the report. One per window; the File menu command reaches
/// the key window's instance through a focused value.
@MainActor @Observable public final class BackupCommands {
    public let model: BackupModel
    private let time: any TimeSource

    public init(services: GlossServices) {
        self.model = BackupModel(services: services)
        self.time = services.time
    }

    /// File › back up library…: asks where (the cli's default name), never overwrites, and
    /// reports at the end. The panel is modal, the standard way for a save from a menu.
    public func begin() {
        guard model.state != .running else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.message = "a consistent copy of your whole library"
        panel.prompt = "back up"
        // The cli names its backups the same way (LibraryBackupNaming, shared).
        panel.nameFieldStringValue = LibraryBackupNaming.fileName(for: time.now())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.backUp(to: url) }
    }
}

/// The File menu item, routed to the key window's flow.
public struct GlossBackupCommands: Commands {
    @FocusedValue(\.backupCommands) private var backup: BackupCommands?

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("back up library…") { backup?.begin() }
                .disabled(backup == nil)
        }
    }
}

extension FocusedValues {
    /// The key window's "back up library…" flow.
    @Entry public var backupCommands: BackupCommands?
}

extension View {
    /// Reports how the backup went: success offers "show in finder", failure says why.
    /// One line on the window (MainWindow applies it).
    public func backupResultAlert(_ commands: BackupCommands) -> some View {
        let model = commands.model
        return alert(Self.backupTitle(model.state),
                     isPresented: Binding(get: { Self.isReported(model.state) },
                                         set: { if !$0 { model.clearResult() } })) {
            if case .done(let url) = model.state {
                Button("show in finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("ok") {}
        } message: {
            switch model.state {
            case .done(let url): Text(verbatim: url.path)
            case .failed(let why): Text(verbatim: why)
            default: Text(verbatim: "")
            }
        }
    }

    private static func isReported(_ state: BackupModel.State) -> Bool {
        switch state {
        case .done, .failed: true
        case .idle, .running: false
        }
    }

    private static func backupTitle(_ state: BackupModel.State) -> String {
        switch state {
        case .done: "backed up your library"
        case .failed: "couldn't back up your library"
        case .idle, .running: ""
        }
    }
}
#endif
