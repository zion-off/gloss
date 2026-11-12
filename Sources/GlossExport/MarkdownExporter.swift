import Foundation
import GlossCore
import GlossMarkdown

/// One markdown file for a notes tree:
///
/// - each page becomes a section headed by its title, nested by depth (the root is `#`);
///   headings inside a page body are demoted beneath its section;
/// - subpage block lines become links to the subpage's section, which follows its parent;
/// - quote lines (`> quote [↗](gloss://passage/…)`) keep the quote and gain a location
///   reference; other passage links become footnotes quoting the passage with its location;
/// - links to pages outside the export, books and anything missing degrade to their label.
public struct MarkdownExporter: Exporter {
    public init() {}
    public var format: ExportFormat { .markdown }
    public var fileExtension: String { "md" }
    public var mimeType: String { "text/markdown" }

    public func export(_ bundle: ExportBundle) throws -> Data {
        Data(compose(bundle).utf8)
    }

    public func compose(_ bundle: ExportBundle) -> String {
        var composer = Composer(bundle: bundle)
        return composer.run()
    }
}

/// GitHub-style heading anchors, unique within one export.
struct Slugger {
    private var used: [String: Int] = [:]

    mutating func slug(_ title: String) -> String {
        let base = title.lowercased().compactMap { char -> String? in
            if char.isLetter || char.isNumber { return String(char) }
            if char == " " || char == "-" { return "-" }
            return nil
        }.joined()
        let slug = base.isEmpty ? "page" : base
        let count = used[slug, default: 0]
        used[slug] = count + 1
        return count == 0 ? slug : "\(slug)-\(count)"
    }
}

private struct Composer {
    let bundle: ExportBundle
    var footnotes: [String] = []
    var footnoteIndex: [LinkTargetID: Int] = [:]
    var anchors: [PageID: String] = [:]

    init(bundle: ExportBundle) {
        self.bundle = bundle
        var slugger = Slugger()
        for (page, _) in bundle.root.walk() {
            anchors[page.id] = slugger.slug(Composer.title(of: page))
        }
    }

    static func title(of page: Page) -> String { page.title.isEmpty ? PageService.untitled : page.title }

    mutating func run() -> String {
        var sections: [String] = []
        for (page, depth) in bundle.root.walk() {
            var section = String(repeating: "#", count: min(6, depth + 1)) + " " + Composer.title(of: page)
            if depth == 0, let document = bundle.document {
                let byline = document.author.isEmpty ? "*\(document.title)*" : "*\(document.title)* · \(document.author)"
                if Composer.title(of: page) != document.title || !document.author.isEmpty { section += "\n\n" + byline }
            }
            let body = transform(page.body, sectionLevel: min(6, depth + 1)).trimmingCharacters(in: .newlines)
            if !body.isEmpty { section += "\n\n" + body }
            sections.append(section)
        }
        var output = sections.joined(separator: "\n\n")
        if !footnotes.isEmpty { output += "\n\n" + footnotes.joined(separator: "\n") }
        return output + "\n"
    }

    /// Rewrites one page body.
    mutating func transform(_ body: String, sectionLevel: Int) -> String {
        let document = MarkdownParser.standard.parse(body)
        var edits: [TextEdit] = []
        // Demote headings below the page's own section heading.
        for block in document.blocks.flatMap(\.flattened) where block.kind == .heading {
            let level = min(6, (block.attributes.level ?? 1) + sectionLevel)
            if let marker = block.syntax.first {
                edits.append(TextEdit(range: marker, replacement: String(repeating: "#", count: level) + " "))
            }
        }
        for link in LinkScanner.links(in: document) {
            guard let glossLink = GlossLink(string: link.destination) else { continue }
            edits.append(TextEdit(range: link.range, replacement: replacement(for: glossLink, link: link)))
        }
        return EditResult(edits: edits, selection: 0..<0).apply(to: body)
    }

    mutating func replacement(for glossLink: GlossLink, link: MarkdownLink) -> String {
        switch glossLink {
        case .page(let id):
            guard let anchor = anchors[id] else { return link.label }
            return "[\(link.label)](#\(anchor))"
        case .document:
            return link.label
        case .passage(let id):
            guard let target = bundle.linkTargets[id] else { return link.plainLabel == QuoteLine.arrow ? "" : link.label }
            let location = locationReference(for: target)
            if link.plainLabel == QuoteLine.arrow {
                return location.isEmpty ? "" : "— *\(location)*"
            }
            return link.label + footnoteMarker(for: target, location: location)
        }
    }

    mutating func footnoteMarker(for target: LinkTarget, location: String) -> String {
        if let existing = footnoteIndex[target.id] { return "[^\(existing)]" }
        let number = footnotes.count + 1
        footnoteIndex[target.id] = number
        let quote = MarkdownEscaping.escapeInline(target.passage.quote, atLineStart: false)
        footnotes.append("[^\(number)]: “\(quote)”" + (location.isEmpty ? "" : " — \(location)"))
        return "[^\(number)]"
    }

    /// "chapter 3", or "chapter 3, *Other Book*" for passages in another book.
    func locationReference(for target: LinkTarget) -> String {
        var parts: [String] = []
        if let label = target.passage.label, !label.isEmpty { parts.append(label) }
        if target.documentID != bundle.root.page.documentID, let title = bundle.documentTitles[target.documentID] {
            parts.append("*\(title)*")
        }
        return parts.joined(separator: ", ")
    }
}
