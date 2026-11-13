#if os(macOS)
import AppKit
import WebKit
import GlossReaderBridge
import GlossReaderKit

/// foliate-js in a WKWebView (docs/READER_BRIDGE.md): the reader page and books come from the
/// scheme handler, events arrive as JSON text from the `gloss` message handler and go through
/// the inbox, commands go in through `callAsyncJavaScript`.
@MainActor
final class EPUBReaderSession: NSObject, ReaderSession, WKNavigationDelegate {
    static let messageHandlerName = "gloss"

    let webView: WKWebView
    var view: NSView { webView }
    var driver: any ReaderDriving { bridge }

    private let bridge: EPUBBridgeDriver
    private let inbox: ReaderEventInbox
    private let contentController: WKUserContentController
    private let messages: ScriptMessageProxy

    init(loader: ReaderResourceLoader, appearance: ReaderAppearance,
         deliver: @escaping @MainActor @Sendable (ReaderEngineEvent) async -> Void) {
        let configuration = WKWebViewConfiguration()
        // Nothing the reader does may outlive the session: no cookies, caches or storage on disk.
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(ReaderSchemeHandler(loader: loader), forURLScheme: ReaderResourceRouter.scheme)
        let messages = ScriptMessageProxy()
        let contentController = configuration.userContentController
        contentController.add(messages, contentWorld: .page, name: Self.messageHandlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)

        self.webView = webView
        self.messages = messages
        self.contentController = contentController
        self.inbox = ReaderEventInbox(deliver: deliver)
        self.bridge = EPUBBridgeDriver(appearance: appearance) { [weak webView] command in
            guard let webView else { throw ReaderDrivingError.notReady }
            // JSON text in, parsed in the page: the glue validates exactly what Swift encoded (D-081).
            _ = try await webView.callAsyncJavaScript("return await window.glossReader.receive(JSON.parse(command))",
                                                      arguments: ["command": try command.encodedString()],
                                                      contentWorld: .page)
        }
        super.init()

        messages.session = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        if let background = Self.color(appearance.colors.background) {
            webView.underPageBackgroundColor = background
        }
        #if DEBUG
        webView.isInspectable = true
        #endif
        _ = webView.load(URLRequest(url: ReaderResourceRouter.indexURL))
    }

    func invalidate() async {
        // Drains: the queued events are delivered (and dropped by the controller's guards)
        // before the next session attaches, so nothing of ours lands after that.
        await inbox.closeAndDrain()
        contentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView.navigationDelegate = nil
        messages.session = nil
    }

    /// A message from the page. Only the reader page itself may talk to the app: book sections
    /// live in frames, and nothing they post is trusted.
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        do {
            if let event = try EPUBBridgeDriver.engineEvent(fromMessageBody: message.body) {
                inbox.post(event)
            }
        } catch {
            inbox.post(.failed("the reader said something gloss didn't understand"))
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let target: ReaderNavigationPolicy.Target
        if let frame = navigationAction.targetFrame {
            target = frame.isMainFrame ? .mainFrame : .subframe
        } else {
            target = .newWindow
        }
        decisionHandler(ReaderNavigationPolicy.allows(navigationAction.request.url, target: target) ? .allow : .cancel)
    }

    /// The web content process died (memory pressure, a crash): reload the page. The glue says
    /// `ready` again and the controller reopens the book where it was.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        _ = webView.reload()
    }

    static func color(_ css: String) -> NSColor? {
        guard let color = CSSColor(hex: css) else { return nil }
        return NSColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: CGFloat(color.alpha))
    }
}

/// The user content controller keeps its handlers alive; this proxy keeps the session out of
/// that retain cycle.
@MainActor
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var session: EPUBReaderSession?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.receive(message)
    }
}
#endif
