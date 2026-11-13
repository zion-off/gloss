import Foundation

/// Which navigations the reader web view allows. The page itself is `gloss-reader://app/index.html`;
/// foliate loads book sections into iframes as `blob:` documents. Nothing else may load: book
/// links reach the app as `linkActivated` events instead, and new windows are never opened.
public enum ReaderNavigationPolicy {
    public enum Target: Sendable {
        case mainFrame
        case subframe
        /// `window.open`, `target="_blank"` (WebKit gives no target frame).
        case newWindow
    }

    public static func allows(_ url: URL?, target: Target) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        switch target {
        case .newWindow:
            return false
        case .mainFrame:
            return scheme == ReaderResourceRouter.scheme && url.host?.lowercased() == ReaderResourceRouter.host
                && url.path == "/index.html"
        case .subframe:
            return scheme == "blob" || url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc"
        }
    }
}
