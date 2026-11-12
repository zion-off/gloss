import Foundation
import GlossCore

// Stable, documented shapes for `--json`. Field names are camelCase; dates are ISO 8601.

struct DocumentJSON: Encodable {
    var id: String
    var url: String
    var kind: String
    var title: String
    var author: String
    var added: Date
    var lastOpened: Date?
    var progress: Double?
    var position: String?
    var fileSize: Int64
    var filename: String?
    var pageCount: Int?
    var language: String?
    var publisher: String?

    init(_ document: Document, position: ReadingPosition? = nil) {
        id = document.id.stringValue
        url = GlossLink.document(document.id).string
        kind = document.kind.rawValue
        title = document.title
        author = document.author
        added = document.addedAt
        lastOpened = document.lastOpenedAt
        progress = position?.progression
        self.position = position?.label
        fileSize = document.fileSize
        filename = document.originalFilename
        pageCount = document.metadata.pageCount
        language = document.metadata.language
        publisher = document.metadata.publisher
    }
}

struct PageJSON: Encodable {
    var id: String
    var url: String
    var bookId: String
    var parentId: String?
    var title: String
    var created: Date
    var updated: Date
    var body: String?
    var children: [PageJSON]?

    init(_ page: Page, includeBody: Bool = false, children: [PageJSON]? = nil) {
        id = page.id.stringValue
        url = GlossLink.page(page.id).string
        bookId = page.documentID.stringValue
        parentId = page.parentID?.stringValue
        title = page.title
        created = page.createdAt
        updated = page.updatedAt
        body = includeBody ? page.body : nil
        self.children = children
    }

    init(tree node: PageTree.Node) {
        self.init(node.page, children: node.children.map(PageJSON.init(tree:)))
    }
}

struct HighlightJSON: Encodable {
    var id: String
    var color: String
    var quote: String
    var location: String?
    var progression: Double?
    var created: Date

    init(_ highlight: Highlight) {
        id = highlight.id.stringValue
        color = highlight.color.rawValue
        quote = highlight.passage.quote
        location = highlight.passage.label
        progression = highlight.passage.progression
        created = highlight.createdAt
    }
}

struct SearchHitJSON: Encodable {
    var group: String
    var title: String
    var subtitle: String?
    var snippet: String
    var matches: [String]
    var url: String?
    var bookId: String?
    var locator: LocatorJSON?

    struct LocatorJSON: Encodable {
        var scheme: String
        var value: String
    }

    init(_ hit: SearchHit) {
        group = hit.group.id
        title = hit.title
        subtitle = hit.subtitle
        snippet = hit.snippet.plainText
        matches = hit.snippet.segments.filter(\.isMatch).map(\.text)
        switch hit.destination {
        case .document(let id):
            url = GlossLink.document(id).string
            bookId = id.stringValue
        case .page(let page, let document, _):
            url = GlossLink.page(page).string
            bookId = document.stringValue
        case .bookText(let document, let locator, _):
            url = GlossLink.document(document).string
            bookId = document.stringValue
            self.locator = locator.map { LocatorJSON(scheme: $0.scheme.rawValue, value: $0.value) }
        }
    }
}

struct TrashEntryJSON: Encodable {
    var id: String
    var kind: String
    var title: String
    var bookId: String?
    var trashed: Date
    var expires: Date?

    init(_ entry: TrashEntry, expires: Date?) {
        id = entry.id.stringValue
        kind = entry.kind.rawValue
        title = entry.title
        bookId = entry.documentID?.stringValue
        trashed = entry.trashedAt
        self.expires = expires
    }
}
