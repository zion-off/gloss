import GlossMarkdown

/// Keeps the `notes` corpus in step with pages. Link destinations are left out of the
/// searchable text so `gloss://…` ids never match a query.
public enum NotesIndexer {
    public static func entry(for page: Page) -> FullTextEntry {
        FullTextEntry(corpus: .notes, owner: page.id.stringValue, documentID: page.documentID,
                      title: page.title, body: searchableText(page.body))
    }

    public static func index(_ page: Page, in tx: any WriteTransaction) throws {
        try tx.fullText.replaceEntries([entry(for: page)], corpus: .notes, owner: page.id.stringValue)
    }

    public static func remove(_ pageID: PageID, in tx: any WriteTransaction) throws {
        try tx.fullText.removeEntries(corpus: .notes, owner: pageID.stringValue)
    }

    /// Markdown without syntax characters (link labels stay, destinations go).
    public static func searchableText(_ body: String) -> String {
        PlainText.strip(body)
    }
}

/// Keeps the `library` corpus (titles and authors) in step with documents.
public enum LibraryIndexer {
    public static func index(_ document: Document, in tx: any WriteTransaction) throws {
        let entry = FullTextEntry(corpus: .library, owner: document.id.stringValue, documentID: document.id,
                                  title: document.title, body: document.author)
        try tx.fullText.replaceEntries([entry], corpus: .library, owner: document.id.stringValue)
    }

    public static func remove(_ documentID: DocumentID, in tx: any WriteTransaction) throws {
        try tx.fullText.removeEntries(corpus: .library, owner: documentID.stringValue)
    }
}

/// Writes extracted book text into the `book-text` corpus.
public enum BookTextIndexer {
    public static func index(_ chunks: [TextChunk], of document: Document, in tx: any WriteTransaction) throws {
        let entries = chunks.filter { !$0.text.isEmpty }.map {
            FullTextEntry(corpus: .bookText, owner: document.id.stringValue, documentID: document.id,
                          locator: $0.locator, label: $0.label, title: $0.label ?? document.title, body: $0.text)
        }
        try tx.fullText.replaceEntries(entries, corpus: .bookText, owner: document.id.stringValue)
    }

    public static func remove(_ documentID: DocumentID, in tx: any WriteTransaction) throws {
        try tx.fullText.removeEntries(corpus: .bookText, owner: documentID.stringValue)
    }
}
