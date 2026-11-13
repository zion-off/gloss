#if os(macOS)
import SwiftUI
import GlossAppModel
import GlossEditor
import GlossExport
import GlossUI

/// The app's entry point. `AppRoot.load()` is the composition root (CLAUDE.md, "Dependency
/// inversion"); each window builds its own models over the shared services. The scene carries
/// an id and `handlesExternalEvents` so a `gloss://` link or a Finder double-click reaches an
/// open window instead of opening a duplicate (D-136).
@main
struct GlossApp: App {
    @State private var root = AppRoot.load()

    var body: some Scene {
        WindowGroup(id: "main") {
            switch root {
            case .success(let root):
                MainWindow(services: root.services, engines: root.engines, export: root.export,
                           prepare: { await root.prepare() })
            case .failure(let failure):
                ContentUnavailableView("gloss couldn't open your library", systemImage: "exclamationmark.triangle",
                                       description: Text(verbatim: failure.message))
            }
        }
        .handlesExternalEvents(matching: ["main"])
        .commands { NotesFormatCommands()
            GlossWindowCommands()
            LibraryCommands()
            GlossExportCommands() }
    }
}
#else
/// The app is macOS-only (D-018). This target still builds on Linux so the package resolves and
/// the compiler parses the Mac sources (D-084); running it here only says so.
@main
enum GlossApp {
    static func main() {
        print("the gloss app runs on macOS; the gloss command works here")
    }
}
#endif
