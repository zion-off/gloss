# Decisions

One line of rationale per decision. Newest entries go at the bottom of each section.

## Environment and tooling

- **D-001 Swift 6.4.2 toolchain on Linux, Swift 6 language mode, tools-version 6.1.** GRDB 7.12
  itself requires tools-version 6.1, so that is the floor; strict concurrency catches races early.
- **D-002 Mac targets stay in the package, sources wrapped in `#if os(macOS)`.** Verified that
  Swift parses inactive `#if` regions on Linux, so syntax errors in Mac code fail the Linux build
  even though it cannot be type-checked; the package resolves identically on both platforms.
- **D-003 System SQLite on Linux has FTS5.** Ubuntu 24.04 ships SQLite 3.45.1 compiled with
  `ENABLE_FTS5` (checked with `PRAGMA compile_options`); GRDB links it through its
  `GRDBSQLite` system-library target. A store test asserts `sqlite_compileoption_used('ENABLE_FTS5')`
  so a Linux box without FTS5 fails loudly instead of silently losing search.
- **D-004 FTS5 is used through raw SQL, not GRDB's FTS5 Swift API.** GRDB's FTS5 helpers are
  behind compile-time flags; plain `CREATE VIRTUAL TABLE … USING fts5` works wherever SQLite has
  FTS5, which keeps the store portable to custom SQLite builds later.
- **D-005 `Observation` is used in `GlossAppModel`.** Verified that `@Observable` and
  `withObservationTracking` work on Linux, so view state can be Linux-tested and SwiftUI binds to
  it directly on the Mac.

## Dependencies

- **D-010 GRDB.swift 7.x** — preferred by the brief; WAL `DatabasePool` gives safe concurrent
  app + CLI access, migrations and a mature SQLite layer.
- **D-011 swift-argument-parser 1.x** — preferred by the brief for the CLI.
- **D-012 swift-crypto** — SHA-256 content addressing on Linux and macOS (CryptoKit is Apple-only).
- **D-013 ZIPFoundation 0.9.x** — EPUBs are ZIP files; a mature reader that handles ZIP64 and data
  descriptors on Linux (system zlib) and Apple (Compression). Its public raw-inflate API also
  decodes PDF `FlateDecode` streams, so no separate zlib binding is needed.
- **D-014 foliate-js, vendored at a pinned commit** — required by the brief; vendored (not fetched)
  so CFI resolution can never change under existing notes. The PDF.js vendor folder is dropped
  because PDFs use PDFKit.
- **D-015 jsdom as a test-only Node dev dependency** — lets the bridge tests drive the real vendored
  `epubcfi.js` against a DOM under Node; it never ships in the app.
- **D-016 No terminal UI dependency** — `GlossTerminal` is ~300 lines of ANSI styling, honouring
  `NO_COLOR` and non-TTY output; not worth a dependency.

## Domain

- **D-020 IDs are UUIDv7 rendered as 26-char lowercase Crockford base32.** Globally unique across
  devices, time-ordered for index locality, and short enough to keep `gloss://` links readable.
- **D-021 `DocumentKind` is an open struct with static members, not an enum.** New formats register
  a kind without editing a switch anywhere.
- **D-022 Passages carry quote, label and progression next to the opaque locator.** Hover popovers,
  the highlights list, the CLI and export work without an engine; ordering never parses locators.
- **D-023 Link targets are reference-counted from page bodies with a 7-day orphan grace period.**
  "Cleaned up automatically" without breaking undo, cut-and-paste or trash restore; unreferenced
  targets have no marker, so the delay is invisible.
- **D-024 References from trashed pages keep targets alive.** Restoring a page must restore working
  links.
- **D-025 Dead links degrade by rewriting the body to the label text.** Matches "links degrade to
  plain text and the line of text is kept", and keeps the stored markdown honest outside the app.
- **D-026 Reusing link targets:** linking the same locator twice in a document reuses the existing
  target, so a passage has one marker and one list of linking notes.
- **D-027 Subpage block line = a line whose only content is a link to a child page.** Pure
  markdown, readable anywhere; children without such a line render after the body, so the tree
  stays authoritative.
- **D-028 Renaming a page updates block-line labels that still equal the old title.** Keeps the
  stored text truthful without touching labels the user customised.
- **D-029 Trash restore pulls in the whole batch of any trashed container.** "A cascade restores
  together" applied recursively gives one predictable rule for ancestors (pages or the document).
- **D-030 Trash TTL is evaluated at sweep time from the current setting.** Changing the TTL (or
  choosing "never") applies to everything already in the trash, which is the least surprising.
- **D-031 Hard deletes write tombstones; trash uses soft deletes.** Highlights and targets are hard
  deleted with a tombstone row (enough for future sync); trashed rows stay until purged.
- **D-032 The root page cannot be trashed alone.** Every document keeps exactly one root page;
  trashing the book trashes the root.

## Storage

- **D-040 One FTS5 table plus an `fts_entries` side table keyed by rowid.** Deleting or filtering
  by owner, corpus or document uses ordinary indexes instead of scanning FTS5 unindexed columns, and
  a new search source is a new corpus string, not a schema change.
- **D-041 A change journal table instead of file watching.** Works identically on Linux and macOS,
  is testable with two pools on one file, and doubles as the seed of a future sync change log.
- **D-042 Derived data lives in clearly separated tables** (`page_refs`, `fts*`, `derived_covers`)
  that `gloss reindex` can drop and rebuild; they are never synced.
- **D-043 Backups use `VACUUM INTO`.** A consistent snapshot of a live WAL database in one statement,
  compacted, readable by any SQLite.

## Markdown (GlossMarkdown)

- **D-050 Own markdown parser instead of swift-markdown/cmark.** Live styling needs exact UTF-16
  ranges for every syntax character, cheap re-parsing per keystroke and pluggable block/inline
  parsers (tables, images later); cmark's line/column AST and reserialisation model fit poorly.
- **D-051 Blocks are line-based.** One block per line (fenced code excepted); paragraphs are not
  merged, so styling maps 1:1 onto editor lines. Exporters merge consecutive paragraph lines.
- **D-052 Inline spans do not cross lines.** Emphasis across soft line breaks is rare in notes and
  would make per-line restyling non-local.
- **D-053 No setext headings and no indented code blocks.** `---` is always a divider and four-space
  indentation stays available for nested lists; both are common sources of surprise in editors.
- **D-054 Emphasis follows CommonMark's delimiter algorithm** (flanking rules, `_` not intraword,
  rule of three); strikethrough is GFM-style `~~`.
- **D-055 "Syntax dims, and shows on the cursor" = two colours, never hidden glyphs.** Syntax
  characters render in a faint colour and at secondary-label strength for every element touching
  the selection. Hiding glyphs would break caret movement and selection in TextKit.
- **D-056 Bold/italic with an empty selection wraps the word under the caret,** or inserts an empty
  pair between words — the common behaviour of native markdown editors.
- **D-057 Text gloss writes into notes is escaped minimally** (`\ * [ ] ~ \``, word-boundary `_`,
  tag-like `<`, leading block markers) so quotes stay readable as plain text.

## Process notes

- **P-001 Commits `7b2…`→`3a19212` of milestone 1 were split from one green check;** the
  intermediate ones may not build on their own. History is not rewritten (commit policy); from
  here on every slice is checked before its own commit.
