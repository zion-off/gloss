#if os(macOS)
import Foundation
import WebKit
import GlossReaderBridge

/// Serves `gloss-reader://` for the reader web view. It only executes
/// `ReaderResourceLoader.response(for:)` (Linux-tested) and hands the answer to WebKit.
///
/// `WKURLSchemeTask` isn't main-actor isolated and raises if called after `webView(_:stop:)`
/// (per Apple's documentation). So tasks stay in `running`, touched only on the main actor; a load
/// finishing after its task was stopped finds nothing there and drops its answer.
@MainActor
final class ReaderSchemeHandler: NSObject, WKURLSchemeHandler {
    private let loader: ReaderResourceLoader
    private var running: [ObjectIdentifier: (task: any WKURLSchemeTask, work: Task<Void, Never>)] = [:]

    init(loader: ReaderResourceLoader) {
        self.loader = loader
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        let loader = self.loader
        // Runs on the main actor only after this method returns, so `running` has the entry.
        let work = Task { @MainActor [weak self] in
            let response = await loader.response(for: url)
            self?.finish(id, url: url, with: response)
        }
        running[id] = (urlSchemeTask, work)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        running.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.work.cancel()
    }

    private func finish(_ id: ObjectIdentifier, url: URL, with response: ReaderResponse) {
        guard let entry = running.removeValue(forKey: id) else { return }  // stopped meanwhile
        guard let http = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1",
                                         headerFields: response.headers) else {
            entry.task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        entry.task.didReceive(http)
        if !response.body.isEmpty { entry.task.didReceive(response.body) }
        entry.task.didFinish()
    }
}
#endif
