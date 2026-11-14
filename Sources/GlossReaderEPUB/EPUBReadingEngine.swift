import Foundation
import GlossCore
import GlossReaderBridge
import GlossReaderKit

/// Reads EPUBs with foliate-js in a web view.
@MainActor
public struct EPUBReadingEngine: ReadingEngine {
    public let kinds: Set<DocumentKind> = [.epub]
    private let loader: ReaderResourceLoader
    private let appearance: @MainActor () -> ReaderAppearance

    /// - Parameters:
    ///   - readerDirectory: the bundled reader (`ReaderBundle.directory()`).
    ///   - appearance: the reading settings to open books with.
    public init(readerDirectory: URL, library: LibraryService, appearance: @escaping @MainActor () -> ReaderAppearance) {
        self.loader = ReaderResourceLoader(readerDirectory: readerDirectory, library: library)
        self.appearance = appearance
    }

    public func makeSession(deliver: @escaping @MainActor @Sendable (ReaderEngineEvent) async -> Void) -> any ReaderSession {
        EPUBReaderSession(loader: loader, appearance: appearance(), deliver: deliver)
    }
}

/// Where the bundled reader lives.
public enum ReaderBundle {
    static let bundleName = "gloss_GlossReaderEPUB.bundle"

    /// The `reader/` directory: in the app's Resources when run as `build/gloss.app`
    /// (scripts/run-mac.sh copies SwiftPM's resource bundle there), else next to the executable
    /// (`swift run GlossMac`).
    public static func directory() -> URL? {
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent(bundleName)),
           let url = bundle.url(forResource: "reader", withExtension: nil) {
            return url
        }
        return Bundle.module.url(forResource: "reader", withExtension: nil)
    }
}
