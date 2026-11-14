import Foundation
import GlossCore
import GlossReaderBridge
import GlossReaderKit

/// Reads PDFs with PDFKit.
@MainActor
public struct PDFReadingEngine: ReadingEngine {
    public let kinds: Set<DocumentKind> = [.pdf]
    private let library: LibraryService
    private let appearance: @MainActor () -> ReaderAppearance

    public init(library: LibraryService, appearance: @escaping @MainActor () -> ReaderAppearance) {
        self.library = library
        self.appearance = appearance
    }

    public func makeSession(deliver: @escaping @MainActor @Sendable (ReaderEngineEvent) async -> Void) -> any ReaderSession {
        PDFReaderSession(library: library, appearance: appearance(), deliver: deliver)
    }
}
