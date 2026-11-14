#if os(macOS)
import SwiftUI
import GlossAppModel
import GlossEditor
import GlossExport
import GlossUI

/// The app's entry point. `AppRoot.load()` is the composition root (CLAUDE.md, "Dependency
/// inversion"); each window builds its own models over the shared services. A `gloss://` link or
/// a Finder double-click goes to an open window (`externalURLHandling` prefers every URL there),
/// and opens a window of this scene when none is open.
@main
struct GlossApp: App {
    @State private var root = AppRoot.load()
    @State private var commandLineTool = CommandLineToolActions()
    @State private var updates = Updates()

    var body: some Scene {
        WindowGroup(id: "main") {
            switch root {
            case .success(let root):
                MainWindow(services: root.services, engines: root.engines, export: root.export,
                           backupActivity: root.backupActivity,
                           prepare: { await root.prepare() })
            case .failure(let failure):
                ContentUnavailableView("gloss couldn't open your library", systemImage: "exclamationmark.triangle",
                                       description: Text(verbatim: failure.message))
            }
        }
        .handlesExternalEvents(matching: ["*"])
        .commands { NotesFormatCommands()
            GlossWindowCommands()
            LibraryCommands()
            GlossExportCommands()
            GlossBackupCommands()
            GlossCommandLineToolCommands(actions: commandLineTool)
            GlossUpdateCommands(updates: updates) }
        Settings {
            switch root {
            case .success(let root):
                GlossSettingsView(model: root.settingsModel, backup: root.automaticBackup)
            case .failure(let failure):
                ContentUnavailableView("gloss couldn't open your library", systemImage: "exclamationmark.triangle",
                                       description: Text(verbatim: failure.message))
            }
        }
    }
}
#else
/// The app is macOS-only. This target still builds on Linux so the package resolves and
/// the compiler parses the Mac sources; running it here only says so.
@main
enum GlossApp {
    static func main() {
        print("the gloss app runs on macOS; the gloss command works here")
    }
}
#endif
