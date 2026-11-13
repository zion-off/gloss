// Stand-in for WebKit, for scripts/mac-typecheck.py (D-099). Declarations copied from Apple's
// documentation JSON (documentation/webkit/...), as recorded in docs/MAC_API_NOTES.md: WKWebView
// and its configuration classes are `@MainActor`, the handler and delegate protocols are
// `@MainActor`, and `WKURLSchemeTask` is not isolated.

import AppKit

/// webkit/wkurlschemetask — NOT main-actor isolated
public protocol WKURLSchemeTask: NSObjectProtocol {
    var request: URLRequest { get }
    func didReceive(_ response: URLResponse)
    func didReceive(_ data: Data)
    func didFinish()
    func didFailWithError(_ error: any Error)
}

/// webkit/wkurlschemehandler — `@MainActor protocol WKURLSchemeHandler : NSObjectProtocol`
@MainActor public protocol WKURLSchemeHandler: NSObjectProtocol {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask)
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask)
}

/// webkit/wkscriptmessagehandler
@MainActor public protocol WKScriptMessageHandler: NSObjectProtocol {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage)
}

/// webkit/wknavigationdelegate — every requirement optional
@MainActor public protocol WKNavigationDelegate: NSObjectProtocol {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void)
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView)
}
extension WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {}
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {}
}

/// webkit/wkuidelegate
@MainActor public protocol WKUIDelegate: NSObjectProtocol {}

/// webkit/wknavigationactionpolicy
public enum WKNavigationActionPolicy: Int, Sendable { case cancel, allow, download }

/// webkit/wknavigation
@MainActor open class WKNavigation: NSObject {}

/// webkit/wkframeinfo
@MainActor open class WKFrameInfo: NSObject {
    open var isMainFrame: Bool { true }
    open var request: URLRequest { fatalError() }
}

/// webkit/wknavigationaction
@MainActor open class WKNavigationAction: NSObject {
    open var request: URLRequest { fatalError() }
    open var targetFrame: WKFrameInfo? { nil }
}

/// webkit/wkcontentworld
@MainActor open class WKContentWorld: NSObject {
    open class var page: WKContentWorld { WKContentWorld() }
    open class var defaultClient: WKContentWorld { WKContentWorld() }
}

/// webkit/wkscriptmessage
@MainActor open class WKScriptMessage: NSObject {
    open var body: Any { 0 }
    open var frameInfo: WKFrameInfo { WKFrameInfo() }
    open var world: WKContentWorld { WKContentWorld() }
    open var name: String { "" }
}

/// webkit/wkusercontentcontroller
@MainActor open class WKUserContentController: NSObject {
    open func add(_ scriptMessageHandler: any WKScriptMessageHandler, name: String) {}
    open func add(_ scriptMessageHandler: any WKScriptMessageHandler, contentWorld world: WKContentWorld, name: String) {}
    open func removeScriptMessageHandler(forName name: String) {}
    open func removeAllScriptMessageHandlers() {}
}

/// webkit/wkwebsitedatastore
@MainActor open class WKWebsiteDataStore: NSObject {
    @discardableResult open class func nonPersistent() -> WKWebsiteDataStore { WKWebsiteDataStore() }
    @discardableResult open class func `default`() -> WKWebsiteDataStore { WKWebsiteDataStore() }
}

/// webkit/wkwebviewconfiguration — `WKWebViewConfiguration()` has no docs page (UNVERIFIED, MAC_API_NOTES.md)
@MainActor open class WKWebViewConfiguration: NSObject {
    open var websiteDataStore: WKWebsiteDataStore { get { fatalError() } set {} }
    open var userContentController: WKUserContentController { get { fatalError() } set {} }
    open func setURLSchemeHandler(_ urlSchemeHandler: (any WKURLSchemeHandler)?, forURLScheme urlScheme: String) {}
}

/// webkit/wkwebview
@MainActor open class WKWebView: NSView {
    public init(frame: CGRect, configuration: WKWebViewConfiguration) { super.init(frame: frame) }
    public required init?(coder: NSCoder) { super.init(frame: .zero) }
    open var navigationDelegate: (any WKNavigationDelegate)? { get { nil } set {} }
    open var uiDelegate: (any WKUIDelegate)? { get { nil } set {} }
    open var allowsBackForwardNavigationGestures: Bool { get { false } set {} }
    /// macOS 12.0+
    open var underPageBackgroundColor: NSColor! { get { nil } set {} }
    /// macOS 13.3+
    open var isInspectable: Bool { get { false } set {} }
    @discardableResult open func load(_ request: URLRequest) -> WKNavigation? { nil }
    @discardableResult open func reload() -> WKNavigation? { nil }
    /// webkit/wkwebview/callasyncjavascript(_:arguments:in:contentworld:) — async, macOS 12.0+
    @discardableResult @MainActor @preconcurrency open func callAsyncJavaScript(_ functionBody: String, arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil, contentWorld: WKContentWorld) async throws -> Any? { nil }
    @discardableResult @MainActor @preconcurrency open func evaluateJavaScript(_ javaScript: String, in frame: WKFrameInfo? = nil, contentWorld: WKContentWorld) async throws -> Any? { nil }
}
