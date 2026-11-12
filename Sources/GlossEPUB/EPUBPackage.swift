import Foundation
import GlossArchive

public enum EPUBError: Error, Equatable, Sendable {
    case notAnEPUB
    case malformed(String)
}

/// The parts of an EPUB gloss needs on the import side: metadata, spine, table of contents
/// and cover. Reading itself is foliate-js's job.
public struct EPUBPackage: Sendable {
    public struct ManifestItem: Hashable, Sendable {
        public var id: String
        /// Path inside the ZIP, resolved against the OPF location.
        public var path: String
        public var mediaType: String
        public var properties: Set<String>
    }

    public struct TOCEntry: Hashable, Sendable {
        public var label: String
        /// Path inside the ZIP, without fragment.
        public var path: String
        public var fragment: String?
        public var children: [TOCEntry]

        public var flattened: [TOCEntry] { [self] + children.flatMap(\.flattened) }
    }

    public var title: String?
    public var authors: [String]
    public var language: String?
    public var publisher: String?
    public var identifier: String?
    public var date: String?
    public var manifest: [ManifestItem]
    /// Spine items in reading order.
    public var spine: [ManifestItem]
    public var toc: [TOCEntry]
    public var coverItem: ManifestItem?

    let archive: ZipArchive

    public init(data: Data) throws {
        let archive: ZipArchive
        do { archive = try ZipArchive(data: data) } catch { throw EPUBError.notAnEPUB }
        self.archive = archive
        guard let containerData = try? archive.data(at: "META-INF/container.xml") else { throw EPUBError.notAnEPUB }
        let container = try XMLNode.parse(containerData)
        guard let opfPath = container.descendants("rootfile").first(where: {
            ($0.attribute("media-type") ?? "application/oebps-package+xml") == "application/oebps-package+xml"
        })?.attribute("full-path") else { throw EPUBError.malformed("container.xml names no package document") }
        guard let opfData = try? archive.data(at: Self.decodePath(opfPath)) else { throw EPUBError.malformed("missing \(opfPath)") }
        let opf = try XMLNode.parse(opfData)
        let base = Self.directory(of: Self.decodePath(opfPath))

        let metadata = opf.first("metadata") ?? XMLNode(name: "metadata", attributes: [:])
        func dc(_ name: String) -> [XMLNode] { metadata.descendants(name) }
        func clean(_ value: String?) -> String? {
            let trimmed = value?.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        title = clean(dc("title").first?.allText)
        // Prefer creators marked as authors (EPUB2 opf:role or EPUB3 refinements); else all.
        let creators = dc("creator")
        let refinedRoles = Dictionary(metadata.descendants("meta").compactMap { meta -> (String, String)? in
            guard meta.attribute("property") == "role", let refines = meta.attribute("refines") else { return nil }
            return (String(refines.drop { $0 == "#" }), meta.allText)
        }, uniquingKeysWith: { first, _ in first })
        let authorsOnly = creators.filter { node in
            let role = node.attribute("role") ?? node.attribute("id").flatMap { refinedRoles[$0] }
            return role == nil || role == "aut"
        }
        authors = (authorsOnly.isEmpty ? creators : authorsOnly).compactMap { clean($0.allText) }
        language = clean(dc("language").first?.allText)
        publisher = clean(dc("publisher").first?.allText)
        identifier = clean(dc("identifier").first?.allText)
        date = clean(dc("date").first?.allText)

        manifest = (opf.first("manifest")?.all("item") ?? []).compactMap { item in
            guard let id = item.attribute("id"), let href = item.attribute("href") else { return nil }
            return ManifestItem(id: id, path: Self.resolve(href, against: base), mediaType: item.attribute("media-type") ?? "",
                                properties: Set((item.attribute("properties") ?? "").split(separator: " ").map(String.init)))
        }
        let byID = Dictionary(manifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spineNode = opf.first("spine")
        spine = (spineNode?.all("itemref") ?? []).compactMap { $0.attribute("idref").flatMap { byID[$0] } }

        // Cover: EPUB3 property, EPUB2 <meta name="cover">, then a manifest guess.
        let metaCover = metadata.descendants("meta").first { $0.attribute("name") == "cover" }?.attribute("content")
        coverItem = manifest.first { $0.properties.contains("cover-image") }
            ?? metaCover.flatMap { byID[$0] }.flatMap { $0.mediaType.hasPrefix("image/") ? $0 : nil }
            ?? manifest.first { $0.mediaType.hasPrefix("image/") && ($0.id.lowercased().contains("cover") || $0.path.lowercased().contains("cover")) }

        // Table of contents: EPUB3 nav, then NCX.
        var toc: [TOCEntry] = []
        if let nav = manifest.first(where: { $0.properties.contains("nav") }), let data = try? archive.data(at: nav.path),
           let root = try? XMLNode.parse(data) {
            let navs = root.descendants("nav")
            let tocNav = navs.first { ($0.attribute("type") ?? "").split(separator: " ").contains("toc") } ?? navs.first
            if let list = tocNav?.descendants("ol").first {
                toc = Self.navEntries(list, base: Self.directory(of: nav.path))
            }
        }
        if toc.isEmpty {
            let ncxItem = spineNode?.attribute("toc").flatMap { byID[$0] } ?? manifest.first { $0.mediaType == "application/x-dtbncx+xml" }
            if let ncxItem, let data = try? archive.data(at: ncxItem.path), let root = try? XMLNode.parse(data),
               let navMap = root.descendants("navMap").first {
                toc = Self.ncxEntries(navMap, base: Self.directory(of: ncxItem.path))
            }
        }
        self.toc = toc
    }

    public func data(of item: ManifestItem) throws -> Data { try archive.data(at: item.path) }

    /// The TOC label for a spine item: the first TOC entry pointing into it.
    public func label(forSpineIndex index: Int) -> String? {
        guard spine.indices.contains(index) else { return nil }
        let path = spine[index].path
        return toc.flatMap(\.flattened).first { $0.path == path }?.label
    }

    // MARK: TOC parsing

    private static func navEntries(_ list: XMLNode, base: String) -> [TOCEntry] {
        list.all("li").compactMap { li in
            let anchor = li.first("a") ?? li.first("span")
            let label = anchor?.allText ?? ""
            let children = li.first("ol").map { navEntries($0, base: base) } ?? []
            guard !label.isEmpty || !children.isEmpty else { return nil }
            let (path, fragment) = split(anchor?.attribute("href") ?? "", base: base)
            return TOCEntry(label: label, path: path, fragment: fragment, children: children)
        }
    }

    private static func ncxEntries(_ node: XMLNode, base: String) -> [TOCEntry] {
        node.all("navPoint").map { point in
            let label = point.first("navLabel")?.allText ?? ""
            let (path, fragment) = split(point.first("content")?.attribute("src") ?? "", base: base)
            return TOCEntry(label: label, path: path, fragment: fragment, children: ncxEntries(point, base: base))
        }
    }

    private static func split(_ href: String, base: String) -> (String, String?) {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first.map { resolve(String($0), against: base) } ?? ""
        return (path, parts.count > 1 ? String(parts[1]) : nil)
    }

    // MARK: Paths

    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }

    static func decodePath(_ path: String) -> String { path.removingPercentEncoding ?? path }

    /// Resolves a relative href (percent-encoded, may contain `..`) against a directory.
    static func resolve(_ href: String, against base: String) -> String {
        let decoded = decodePath(href)
        let combined = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : base + decoded
        var parts: [Substring] = []
        for part in combined.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }
}
