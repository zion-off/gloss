import SwiftUI
import GlossAppModel

/// Routes URLs from outside into the window: `gloss://` links from other apps and
/// `gloss open`, book files Finder double-clicked. Everything goes through the one portable
/// door, `AppModel.open(url:)`; what it can't open comes back as a small alert.
extension View {
    /// - Parameter ready: whether the window has started (its library loaded, its layout
    ///   restored). A URL that arrives before then waits: one that opened the app, or a new
    ///   window, was routed while the window was still loading, and the restored layout and the
    ///   first library load then undid where it went.
    public func externalURLHandling(app: AppModel, ready: Bool) -> some View {
        modifier(ExternalURLHandling(app: app, ready: ready))
    }
}

private struct ExternalURLHandling: ViewModifier {
    let app: AppModel
    let ready: Bool
    @State private var waiting: [URL] = []

    func body(content: Content) -> some View {
        content
            // An open window takes every URL, so a link reaches the window already showing
            // instead of opening a second one (the scene's own matching only decides when a URL
            // may open a new window).
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onOpenURL { url in
                if ready { Task { await app.open(url: url) } } else { waiting.append(url) }
            }
            .onChange(of: ready, initial: true) { _, ready in
                guard ready, !waiting.isEmpty else { return }
                let urls = waiting
                waiting = []
                Task { for url in urls { await app.open(url: url) } }
            }
            .alert("gloss couldn't open that", isPresented: Binding(
                get: { app.externalURLMessage != nil },
                set: { if !$0 { app.dismissExternalURLMessage() } })) {
                Button("ok") { app.dismissExternalURLMessage() }
            } message: {
                Text(verbatim: app.externalURLMessage ?? "")
            }
    }
}
