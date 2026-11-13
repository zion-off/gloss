import Crypto
import Foundation
import GlossCore

/// What a `gloss-reader://` request asks for. The Mac scheme handler only executes the answer:
/// read a bundled reader file, or stream a book's bytes from the blob store.
public enum ReaderResource: Equatable, Sendable {
    /// A file of the bundled reader, relative to `Resources/reader/`.
    case readerFile(path: String, mimeType: String)
    /// The bytes of a document, from the blob store.
    case book(DocumentID)
    case notFound
}

/// Routes `gloss-reader://app/…` URLs (docs/READER_BRIDGE.md, "Transport"):
///
///     gloss-reader://app/index.html        the reader page
///     gloss-reader://app/glue.js, foliate/…, bridge/…, reader.css
///     gloss-reader://app/book/<documentID> the book file
///
/// Anything else, any `..` segment, hidden files and unknown file types are refused.
public struct ReaderResourceRouter: Sendable {
    public static let scheme = "gloss-reader"
    public static let host = "app"

    public static var indexURL: URL { URL(string: "\(scheme)://\(host)/index.html")! }

    public static func bookURL(_ id: DocumentID) -> URL {
        URL(string: "\(scheme)://\(host)/book/\(id.stringValue)")!
    }

    public init() {}

    public func route(_ url: URL) -> ReaderResource {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.host else { return .notFound }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }) else {
            return .notFound
        }
        if segments.count == 2, segments[0] == "book" {
            return DocumentID(segments[1]).map(ReaderResource.book) ?? .notFound
        }
        let path = segments.joined(separator: "/")
        guard let mimeType = Self.mimeTypes[(path as NSString).pathExtension.lowercased()] else { return .notFound }
        return .readerFile(path: path, mimeType: mimeType)
    }

    /// File types the reader serves. Module scripts must be `text/javascript` or WebKit refuses them.
    static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json",
        "svg": "image/svg+xml",
        "png": "image/png",
        "woff2": "font/woff2",
    ]

    public static let bookMimeType = "application/epub+zip"

    /// Response headers. Nothing is cached: the web view's data store is non-persistent anyway,
    /// and book bytes must never outlive the session. `nosniff` keeps WebKit to the declared
    /// type: `script-src 'self'` covers `/book/<id>` too, and a book must not be able to load
    /// another imported file as a script (review 3).
    public static func headers(mimeType: String, length: Int) -> [String: String] {
        ["Content-Type": mimeType, "Content-Length": String(length), "Cache-Control": "no-store",
         "X-Content-Type-Options": "nosniff"]
    }
}

/// The reader page's Content-Security-Policy. Book sections load as `blob:` documents that
/// inherit it, so scripts inside a book never run, while their styles, images and fonts do.
/// The page's one inline script, the import map, is allowed by its hash.
public enum ReaderPagePolicy {
    public static func contentSecurityPolicy(importMapHash: String) -> String {
        [
            "default-src 'none'",
            "script-src 'self' '\(importMapHash)'",
            "style-src 'self' 'unsafe-inline' blob:",
            "img-src 'self' blob: data:",
            "font-src 'self' blob: data:",
            "media-src blob: data:",
            "frame-src blob:",
            "connect-src 'self' blob:",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
    }

    /// The CSP hash source (`sha256-…`) of the `<script type="importmap">` in `html`.
    public static func importMapHash(html: String) -> String? {
        guard let open = html.range(of: #"<script type="importmap">"#),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else { return nil }
        let content = String(html[open.upperBound..<close.lowerBound])
        return "sha256-" + Data(SHA256.hash(data: Data(content.utf8))).base64EncodedString()
    }

    /// The policy in the page's `<meta http-equiv="Content-Security-Policy">`.
    public static func declaredPolicy(html: String) -> String? {
        guard let meta = html.range(of: #"<meta http-equiv="Content-Security-Policy" content=""#),
              let end = html.range(of: "\"", range: meta.upperBound..<html.endIndex) else { return nil }
        return String(html[meta.upperBound..<end.lowerBound])
    }
}
