import Foundation
import GlossCore

/// A complete answer to a `gloss-reader://` request, ready for the scheme handler to hand to
/// WebKit as an HTTP response.
public struct ReaderResponse: Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public static func ok(_ body: Data, mimeType: String) -> ReaderResponse {
        ReaderResponse(statusCode: 200, headers: ReaderResourceRouter.headers(mimeType: mimeType, length: body.count), body: body)
    }

    /// An empty error response (`fetch` sees `ok == false`, the page sees a failed load).
    public static func failure(_ statusCode: Int) -> ReaderResponse {
        ReaderResponse(statusCode: statusCode, headers: ReaderResourceRouter.headers(mimeType: "text/plain; charset=utf-8", length: 0), body: Data())
    }

    public static let notFound = failure(404)
    public static let serverError = failure(500)
}

/// Answers `gloss-reader://` requests: reader files from
/// the bundled `Resources/reader/` directory, books from the blob store. The Mac scheme handler
/// only forwards the request URL here and the response back to WebKit.
///
/// Only live EPUBs are served: PDFs open natively, and a trashed book is gone as far as the
/// reader is concerned.
public struct ReaderResourceLoader: Sendable {
    private let router = ReaderResourceRouter()
    private let readerDirectory: URL
    private let library: LibraryService

    /// - Parameter readerDirectory: the bundled `reader/` directory (`index.html`, `glue.js`, …).
    public init(readerDirectory: URL, library: LibraryService) {
        self.readerDirectory = readerDirectory
        self.library = library
    }

    public func response(for url: URL) async -> ReaderResponse {
        switch router.route(url) {
        case .readerFile(let path, let mimeType):
            return await readerFile(path, mimeType: mimeType)
        case .book(let id):
            return await book(id)
        case .notFound:
            return .notFound
        }
    }

    private func readerFile(_ path: String, mimeType: String) async -> ReaderResponse {
        // The router refused `..`, empty and hidden segments, so the path stays inside the directory.
        let file = readerDirectory.appendingPathComponent(path, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .notFound
        }
        // Off the main actor: the scheme handler calls this while serving.
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }.value
        guard let data else { return .serverError }
        return .ok(data, mimeType: mimeType)
    }

    private func book(_ id: DocumentID) async -> ReaderResponse {
        do {
            guard let document = try await library.document(id), document.trash == nil, document.kind == .epub else {
                return .notFound
            }
            return .ok(try await library.fileData(of: id), mimeType: ReaderResourceRouter.bookMimeType)
        } catch GlossError.notFound {
            return .notFound
        } catch {
            return .serverError
        }
    }
}
