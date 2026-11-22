import Foundation
import GlossCore
import GRDB

/// Turns what a user types into an FTS5 query: every word must appear, as a prefix.
public enum FTSQueryBuilder {
    public static func build(_ text: String) -> String? {
        let words = TextMatcher.words(in: text).map { String(text[$0.range]) }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
    }

    static let matchStart = "\u{2}"
    static let matchEnd = "\u{3}"

    /// Parses FTS5 `snippet()` output marked with \u{2}…\u{3}.
    static func snippet(from marked: String) -> Snippet {
        var segments: [Snippet.Segment] = []
        var rest = Substring(marked.replacingOccurrences(of: "\n", with: " "))
        while let start = rest.range(of: matchStart) {
            if start.lowerBound > rest.startIndex { segments.append(.init(text: String(rest[..<start.lowerBound]), isMatch: false)) }
            rest = rest[start.upperBound...]
            if let end = rest.range(of: matchEnd) {
                segments.append(.init(text: String(rest[..<end.lowerBound]), isMatch: true))
                rest = rest[end.upperBound...]
            } else {
                segments.append(.init(text: String(rest), isMatch: true))
                rest = ""
            }
        }
        if !rest.isEmpty { segments.append(.init(text: String(rest), isMatch: false)) }
        return Snippet(segments: segments)
    }
}

extension SQLiteTransaction: FullTextIndexing {
    func search(_ query: FullTextQuery) throws -> [FullTextHit] {
        guard let match = FTSQueryBuilder.build(query.text) else { return [] }
        var sql = """
            SELECT e.corpus, e.owner, e.document_id, e.locator_scheme, e.locator, e.label, fts.title,
                   snippet(fts, -1, char(2), char(3), '…', 18) AS snip, bm25(fts, 4.0, 1.0) AS rank
            FROM fts JOIN fts_entries e ON e.rowid = fts.rowid
            WHERE fts MATCH ? AND e.corpus = ?
            """
        var arguments: StatementArguments = [match, query.corpus.rawValue]
        if let documentID = query.documentID {
            sql += " AND e.document_id = ?"
            _ = arguments.append(contentsOf: [documentID.stringValue])
        }
        sql += " ORDER BY rank"
        if let limit = query.limit {
            sql += " LIMIT ?"
            _ = arguments.append(contentsOf: [limit])
        }
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            let locator = (row["locator_scheme"] as String?).map { Locator(scheme: LocatorScheme($0), value: row["locator"] ?? "") }
            return FullTextHit(corpus: Corpus(row["corpus"] as String), owner: row["owner"], documentID: try Columns.optionalID(row, "document_id"),
                               locator: locator, label: row["label"], title: row["title"],
                               snippet: FTSQueryBuilder.snippet(from: row["snip"] ?? ""), rank: row["rank"])
        }
    }

    func entries(corpus: Corpus, documentID: DocumentID) throws -> [FullTextEntry] {
        let sql = """
            SELECT e.owner, e.locator_scheme, e.locator, e.label, fts.title, fts.body
            FROM fts_entries e JOIN fts ON fts.rowid = e.rowid
            WHERE e.corpus = ? AND e.document_id = ?
            ORDER BY e.rowid
            """
        return try Row.fetchAll(db, sql: sql, arguments: [corpus.rawValue, documentID.stringValue]).map { row in
            let locator = (row["locator_scheme"] as String?).map { Locator(scheme: LocatorScheme($0), value: row["locator"] ?? "") }
            return FullTextEntry(corpus: corpus, owner: row["owner"], documentID: documentID, locator: locator,
                                 label: row["label"], title: row["title"] ?? "", body: row["body"] ?? "")
        }
    }

    func replaceEntries(_ entries: [FullTextEntry], corpus: Corpus, owner: String) throws {
        try removeEntries(corpus: corpus, owner: owner)
        for entry in entries {
            try db.execute(sql: "INSERT INTO fts_entries (corpus, owner, document_id, locator_scheme, locator, label) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [corpus.rawValue, owner, entry.documentID?.stringValue, entry.locator?.scheme.rawValue,
                                       entry.locator?.value, entry.label])
            try db.execute(sql: "INSERT INTO fts (rowid, title, body) VALUES (?, ?, ?)",
                           arguments: [db.lastInsertedRowID, entry.title, entry.body])
        }
    }

    private func removeRows(where condition: String, _ arguments: StatementArguments) throws {
        try db.execute(sql: "DELETE FROM fts WHERE rowid IN (SELECT rowid FROM fts_entries WHERE \(condition))", arguments: arguments)
        try db.execute(sql: "DELETE FROM fts_entries WHERE \(condition)", arguments: arguments)
    }

    func removeEntries(corpus: Corpus, owner: String) throws {
        try removeRows(where: "corpus = ? AND owner = ?", [corpus.rawValue, owner])
    }

    func removeEntries(corpus: Corpus, documentID: DocumentID) throws {
        try removeRows(where: "corpus = ? AND document_id = ?", [corpus.rawValue, documentID.stringValue])
    }

    func removeAllEntries(corpus: Corpus) throws {
        try removeRows(where: "corpus = ?", [corpus.rawValue])
    }
}
