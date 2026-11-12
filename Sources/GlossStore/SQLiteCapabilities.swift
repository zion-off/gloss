import GRDB

/// Facts about the SQLite library GRDB is linked against.
public enum SQLiteCapabilities {
    /// Whether FTS5 is compiled in. gloss needs it for book-text and notes search
    /// (docs/DECISIONS.md D-003).
    public static func hasFTS5(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT sqlite_compileoption_used('ENABLE_FTS5')") ?? false
    }

    public static func version(_ db: Database) throws -> String {
        try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "unknown"
    }
}
