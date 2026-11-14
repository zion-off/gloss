#if os(macOS)
import SwiftUI
import GlossAppModel

/// Routes URLs from outside into the window: `gloss://` links from other apps and
/// `gloss open`, book files Finder double-clicked. Everything goes through the one portable
/// door, `AppModel.open(url:)`; what it can't open comes back as a small alert.
extension View {
    public func externalURLHandling(app: AppModel) -> some View {
        onOpenURL { url in
            Task { await app.open(url: url) }
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
#endif
