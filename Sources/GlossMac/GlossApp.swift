#if os(macOS)
import SwiftUI
import GlossEditor
import GlossUI

/// The app's entry point. `AppRoot.load()` is the composition root (CLAUDE.md, "Dependency
/// inversion"); each window builds its own models over the shared services.
@main
struct GlossApp: App {
    @State private var root = AppRoot.load()

    var body: some Scene {
        WindowGroup {
            switch root {
            case .success(let root):
                MainWindow(services: root.services, engines: root.engines, prepare: { await root.prepare() })
            case .failure(let failure):
                ContentUnavailableView("gloss couldn't open your library", systemImage: "exclamationmark.triangle",
                                       description: Text(verbatim: failure.message))
            }
        }
        .commands { NotesFormatCommands()
            GlossWindowCommands()
            LibraryCommands() }
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
