import Foundation
import GlossCore
import GlossMemoryStore

/// A trivial document format for tests:
///
///     FAKEDOC
///     title: Slouching Towards Bethlehem
///     author: Joan Didion
///     ---
///     first chapter text
///     ===
///     second chapter text
public struct FakeFormat: DocumentFormat, TextExtracting, CoverExtracting {
    public static let kind = DocumentKind("fake")
    public static let scheme = LocatorScheme("fake")

    public init() {}

    public var kind: DocumentKind { Self.kind }
    public var badge: String { "fake" }
    public var shelf: LibraryShelf { .books }
    public var shelfSymbol: String { "book" }
    public var fileExtensions: [String] { ["fake"] }

    public func sniff(_ prefix: Data) -> Bool { prefix.starts(with: Data("FAKEDOC".utf8)) }

    public func readMetadata(from data: Data) throws -> ImportedMetadata {
        let header = String(decoding: data, as: UTF8.self).components(separatedBy: "\n---\n")[0]
        var result = ImportedMetadata()
        for line in header.split(separator: "\n") {
            if line.hasPrefix("title: ") { result.title = String(line.dropFirst(7)) }
            if line.hasPrefix("author: ") { result.author = String(line.dropFirst(8)) }
        }
        return result
    }

    public func extractText(from data: Data) throws -> [TextChunk] {
        let parts = String(decoding: data, as: UTF8.self).components(separatedBy: "\n---\n")
        guard parts.count > 1 else { return [] }
        return parts[1].components(separatedBy: "\n===\n").enumerated().map { index, text in
            TextChunk(locator: Locator(scheme: Self.scheme, value: "section-\(index)"), label: "chapter \(index + 1)", text: text)
        }
    }

    public func extractCover(from data: Data) throws -> CoverImage? {
        String(decoding: data, as: UTF8.self).contains("cover: yes") ? CoverImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png") : nil
    }

    public static func file(title: String? = "A Book", author: String? = "An Author", chapters: [String] = ["once upon a time"], cover: Bool = false) -> Data {
        var header = "FAKEDOC\n"
        if let title { header += "title: \(title)\n" }
        if let author { header += "author: \(author)\n" }
        if cover { header += "cover: yes\n" }
        return Data((header + "---\n" + chapters.joined(separator: "\n===\n")).utf8)
    }
}

/// Core services over in-memory storage with deterministic ids and a hand-driven clock.
public struct TestLibrary: Sendable {
    public let services: GlossServices
    public let store: InMemoryLibraryStore
    public let blobs: InMemoryBlobStore
    public let clock: ManualTimeSource

    public init(formats: [any DocumentFormat] = [FakeFormat()]) {
        let clock = ManualTimeSource()
        let store = InMemoryLibraryStore(origin: "test", time: clock)
        let blobs = InMemoryBlobStore()
        self.clock = clock
        self.store = store
        self.blobs = blobs
        self.services = GlossServices(store: store, blobs: blobs, formats: FormatRegistry(formats),
                                      ids: SequentialIDGenerator(), time: clock)
    }

    /// Imports a fake book and returns it with its root page.
    public func book(_ title: String = "A Book", author: String = "An Author", chapters: [String] = ["once upon a time"]) async throws -> (Document, Page) {
        let outcome = try await services.imports.importData(FakeFormat.file(title: title, author: author, chapters: chapters), filename: "\(title).fake")
        let document = outcome.document
        let root = try await services.pages.rootPage(of: document.id)!
        return (document, root)
    }

    public func passage(_ quote: String, at value: String, progression: Double = 0.5) -> Passage {
        Passage(locator: Locator(scheme: FakeFormat.scheme, value: value), quote: quote, label: "chapter 1", progression: progression)
    }
}
