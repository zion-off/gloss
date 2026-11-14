import GRDB

/// The library schema. Migrations are append-only; never edit a shipped migration.
///
/// Authoritative tables hold content that would need syncing. Tables prefixed with `derived_`,
/// plus `page_refs`, `fts_entries` and `fts`, can be dropped and rebuilt at any time
/// (`DerivedDataRebuilder`) and are never synced.
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE blobs (
                hash TEXT PRIMARY KEY NOT NULL,
                size INTEGER NOT NULL,
                data BLOB NOT NULL,
                created_at REAL NOT NULL
            );

            CREATE TABLE documents (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                author TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                original_filename TEXT,
                cover_hash TEXT,
                metadata TEXT NOT NULL,
                added_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                last_opened_at REAL,
                trash_entry TEXT,
                trashed_at REAL
            );
            CREATE INDEX documents_content_hash ON documents(content_hash);
            CREATE INDEX documents_trash_entry ON documents(trash_entry);

            CREATE TABLE pages (
                id TEXT PRIMARY KEY NOT NULL,
                document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                parent_id TEXT REFERENCES pages(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                position REAL NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                trash_entry TEXT,
                trashed_at REAL
            );
            CREATE INDEX pages_document ON pages(document_id);
            CREATE INDEX pages_parent ON pages(parent_id);
            CREATE INDEX pages_trash_entry ON pages(trash_entry);

            CREATE TABLE highlights (
                id TEXT PRIMARY KEY NOT NULL,
                document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                locator_scheme TEXT NOT NULL,
                locator TEXT NOT NULL,
                quote TEXT NOT NULL,
                label TEXT,
                progression REAL,
                color TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE INDEX highlights_document ON highlights(document_id);

            CREATE TABLE link_targets (
                id TEXT PRIMARY KEY NOT NULL,
                document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                locator_scheme TEXT NOT NULL,
                locator TEXT NOT NULL,
                quote TEXT NOT NULL,
                label TEXT,
                progression REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                orphaned_since REAL
            );
            CREATE INDEX link_targets_document ON link_targets(document_id);
            CREATE INDEX link_targets_locator ON link_targets(document_id, locator_scheme, locator);
            CREATE INDEX link_targets_orphaned ON link_targets(orphaned_since) WHERE orphaned_since IS NOT NULL;

            CREATE TABLE reading_positions (
                document_id TEXT PRIMARY KEY NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                locator_scheme TEXT NOT NULL,
                locator TEXT NOT NULL,
                progression REAL NOT NULL,
                label TEXT,
                updated_at REAL NOT NULL
            );

            CREATE TABLE trash_entries (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                document_id TEXT,
                title TEXT NOT NULL,
                trashed_at REAL NOT NULL
            );

            CREATE TABLE settings (
                key TEXT PRIMARY KEY NOT NULL,
                value BLOB NOT NULL,
                updated_at REAL NOT NULL
            );

            CREATE TABLE tombstones (
                entity TEXT NOT NULL,
                id TEXT NOT NULL,
                deleted_at REAL NOT NULL,
                PRIMARY KEY (entity, id)
            );

            CREATE TABLE changes (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                entity TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                origin TEXT NOT NULL,
                at REAL NOT NULL
            );

            -- Derived, rebuildable, never synced.
            CREATE TABLE page_refs (
                page_id TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                ref_id TEXT NOT NULL,
                PRIMARY KEY (page_id, kind, ref_id)
            ) WITHOUT ROWID;
            CREATE INDEX page_refs_target ON page_refs(kind, ref_id);

            CREATE TABLE fts_entries (
                rowid INTEGER PRIMARY KEY,
                corpus TEXT NOT NULL,
                owner TEXT NOT NULL,
                document_id TEXT,
                locator_scheme TEXT,
                locator TEXT,
                label TEXT
            );
            CREATE INDEX fts_entries_owner ON fts_entries(corpus, owner);
            CREATE INDEX fts_entries_document ON fts_entries(corpus, document_id);
            CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize = 'unicode61 remove_diacritics 2');

            CREATE TABLE derived_covers (
                document_id TEXT PRIMARY KEY NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                data BLOB NOT NULL,
                mime_type TEXT NOT NULL
            );
            """)
        }
        return migrator
    }
}
