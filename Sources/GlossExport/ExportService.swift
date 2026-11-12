import Foundation
import GlossCore
import GlossMarkdown

/// An export format. Open: register an `Exporter` for a new one.
public struct ExportFormat: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let markdown = ExportFormat("markdown")
    public static let html = ExportFormat("html")
}

/// What to export.
public enum ExportScope: Hashable, Sendable {
    /// A book's whole notes tree.
    case document(DocumentID)
    /// One page, with or without its subpages.
    case page(PageID, includeSubpages: Bool)
}

/// Everything an exporter needs, gathered up front so exporters are pure functions.
public struct ExportBundle: Sendable {
    public var title: String
    /// Set for whole-book exports.
    public var document: Document?
    public var root: PageTree.Node
    public var linkTargets: [LinkTargetID: LinkTarget]
    public var documentTitles: [DocumentID: String]

    public init(title: String, document: Document?, root: PageTree.Node, linkTargets: [LinkTargetID: LinkTarget] = [:],
                documentTitles: [DocumentID: String] = [:]) {
        self.title = title
        self.document = document
        self.root = root
        self.linkTargets = linkTargets
        self.documentTitles = documentTitles
    }
}

public struct ExportedFile: Hashable, Sendable {
    public var data: Data
    public var filename: String
    public var mimeType: String
}

/// Turns a bundle into a file.
public protocol Exporter: Sendable {
    var format: ExportFormat { get }
    var fileExtension: String { get }
    var mimeType: String { get }
    func export(_ bundle: ExportBundle) throws -> Data
}

/// Gathers bundles from the library and runs the registered exporters.
public struct ExportService: Sendable {
    let store: any LibraryStore
    let exporters: [ExportFormat: any Exporter]

    public init(store: any LibraryStore, exporters: [any Exporter] = ExportService.standardExporters) {
        self.store = store
        self.exporters = Dictionary(exporters.map { ($0.format, $0) }, uniquingKeysWith: { _, last in last })
    }

    public static let standardExporters: [any Exporter] = [MarkdownExporter(), HTMLExporter()]

    public var formats: [ExportFormat] { exporters.keys.sorted { $0.rawValue < $1.rawValue } }

    public func export(_ scope: ExportScope, as format: ExportFormat) async throws -> ExportedFile {
        guard let exporter = exporters[format] else { throw GlossError.notAllowed("gloss can't export \(format) yet") }
        let bundle = try await self.bundle(for: scope)
        return ExportedFile(data: try exporter.export(bundle), filename: Self.filename(for: bundle.title, extension: exporter.fileExtension),
                            mimeType: exporter.mimeType)
    }

    public func bundle(for scope: ExportScope) async throws -> ExportBundle {
        try await store.read { tx in
            let rootPage: Page
            var document: Document?
            var includeSubpages = true
            switch scope {
            case .document(let id):
                guard let found = try tx.documents.document(id) else { throw GlossError.notFound("that book") }
                guard let root = try tx.pages.rootPage(of: id) else { throw GlossError.notFound("the notes for \(found.title)") }
                document = found
                rootPage = root
            case .page(let id, let subpages):
                guard let page = try tx.pages.page(id) else { throw GlossError.notFound("that page") }
                rootPage = page
                includeSubpages = subpages
            }
            let livePages = includeSubpages ? try tx.pages.pages(in: rootPage.documentID, .live) : []
            let tree = Self.subtree(rootPage, pages: livePages)
            var targets: [LinkTargetID: LinkTarget] = [:]
            var titles: [DocumentID: String] = [:]
            for (page, _) in tree.walk() {
                for case .passage(let id) in ReferenceExtractor.references(in: page.body) {
                    guard let target = try tx.linkTargets.linkTarget(id) else { continue }
                    targets[id] = target
                    if titles[target.documentID] == nil { titles[target.documentID] = try tx.documents.document(target.documentID)?.title }
                }
            }
            return ExportBundle(title: document?.title ?? (rootPage.title.isEmpty ? PageService.untitled : rootPage.title),
                                document: document, root: tree, linkTargets: targets, documentTitles: titles)
        }
    }

    static func subtree(_ root: Page, pages: [Page]) -> PageTree.Node {
        let byParent = Dictionary(grouping: pages.filter { $0.parentID != nil }, by: { $0.parentID! })
        func node(_ page: Page) -> PageTree.Node {
            PageTree.Node(page: page, children: (byParent[page.id] ?? []).sorted { ($0.position, $0.id) < ($1.position, $1.id) }.map(node))
        }
        return node(root)
    }

    /// A file name from a title: keeps letters, digits and spaces, everything else becomes "-".
    public static func filename(for title: String, extension ext: String) -> String {
        let cleaned = title.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" ? $0 : "-" }
        let trimmed = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: " -")).prefix(80)
        return (trimmed.isEmpty ? "gloss notes" : String(trimmed)) + "." + ext
    }
}
