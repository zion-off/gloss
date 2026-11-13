# gloss architecture

This is the living design document. It describes the module layout, the data model, the
main protocols (the seams) and the milestone plan. Rationale for individual choices lives in
`DECISIONS.md`; unverified Mac work is tracked in `MACOS_HANDOFF.md`.

## 1. Shape of the system

```
                 ┌──────────────────────────── executables (composition roots) ───────────┐
                 │  gloss (CLI)                               GlossMac (SwiftUI app)       │
                 └───────┬──────────────────────────────────────────┬─────────────────────┘
                         │                                          │
   Linux-buildable       │                                          │        macOS-only
 ┌───────────────────────▼───────────┐            ┌─────────────────▼──────────────────────┐
 │ GlossCLI  GlossTerminal           │            │ GlossUI (SwiftUI views)                │
 │                                   │            │ GlossEditor (TextKit 2 NSTextView)     │
 │ GlossAppModel  (observable view   │◄───────────┤ GlossReaderKit (engine protocol, host) │
 │   state, no UI frameworks)        │            │ GlossReaderEPUB (WKWebView + foliate)  │
 │ GlossNotes (editor logic)         │            │ GlossReaderPDF (PDFKit + overlays)     │
 │ GlossReaderBridge (bridge types,  │            └────────────────────────────────────────┘
 │   appearance CSS, progress text)  │
 │ GlossExport  GlossEPUB  GlossPDF  │
 │ GlossArchive  GlossStore (GRDB)   │
 │ GlossCore (domain, ports,         │
 │   services)  GlossMarkdown        │
 └───────────────────────────────────┘
```

The core is a set of plain Swift services over abstract ports. The CLI and the app are thin
clients that wire concrete implementations at their composition roots:

- `Sources/gloss/main.swift` — the CLI root: SQLite store, EPUB + PDF formats, exporters.
- `Sources/GlossMac/AppRoot.swift` — the app root: the same store and formats plus the reading
  engines, the PDFKit cover renderer and the reader settings; `GlossApp.swift` is the entry point,
  and each window builds its own `AppModel` over the shared services and polls for changes.

## 2. Modules

| Module | Platform | Depends on | One reason to change |
|---|---|---|---|
| `GlossMarkdown` | all | — | markdown syntax: block/inline parsing, styling rules, text edits |
| `GlossCore` | all | GlossMarkdown, swift-crypto | the domain: entities, ports, services, `gloss://` links |
| `GlossStore` | all | GlossCore, GRDB | SQLite persistence: schema, repositories, FTS, blobs, change journal |
| `GlossArchive` | all | ZIPFoundation | reading ZIP containers and raw inflate |
| `GlossEPUB` | all | GlossCore, GlossArchive | EPUB: container/OPF/nav parsing, metadata, cover, text extraction |
| `GlossPDF` | all | GlossCore, GlossArchive | PDF: object parsing, metadata, page text extraction, PDF locators |
| `GlossExport` | all | GlossCore, GlossMarkdown | exporters (markdown, html) |
| `GlossNotes` | all | GlossCore, GlossMarkdown | notes-editor behaviour: styling roles, format commands, slash menu, subpage blocks, link gestures |
| `GlossReaderBridge` | all | GlossCore, GlossEPUB, swift-crypto | the engine-neutral reader boundary (`ReaderDriving`, `ReaderEngineEvent`, `ReaderAnnotations`), the foliate bridge (messages, `EPUBBridgeDriver`), appearance → CSS, progress text, `gloss-reader://` routing and the reader page CSP |
| `GlossReaderPDFSupport` | all | GlossCore, GlossPDF, GlossReaderBridge | the PDF engine's logic that needs no PDFKit: go-to targets, page positions and progress text, annotations per page and hit-testing, selection → passage |
| `GlossAppModel` | all | GlossCore, GlossNotes, GlossReaderBridge | app view state (Observation): library, workspace, navigation, search, trash, import, `ReaderController`, `LinkingCoordinator`, `NotesEditorModel` |
| `GlossTerminal` | all | — | terminal styling: colors, tables, trees, progress |
| `GlossCLI` | all | ArgumentParser + the Linux modules above | CLI commands and output |
| `gloss` | all | GlossCLI | CLI composition root |
| `GlossReaderKit` | macOS | GlossAppModel, GlossReaderBridge | engine registry and the SwiftUI host view (the engine protocol itself is `ReaderDriving` in GlossReaderBridge, so it is Linux-tested) |
| `GlossReaderEPUB` | macOS | GlossReaderKit, GlossReaderBridge | foliate-js in WKWebView, scheme handler, JS glue (resources) |
| `GlossReaderPDF` | macOS | GlossReaderKit, GlossPDF | PDFKit view, selection → locator, overlay highlights/markers |
| `GlossEditor` | macOS | GlossNotes, GlossAppModel | TextKit 2 editor, live styling, format bar, slash menu, subpage rows |
| `GlossUI` | macOS | all of the above | SwiftUI scenes: library, split view, sidebar, search, switcher, trash, settings |
| `GlossMac` | macOS | GlossUI + concrete modules | app composition root: the store, formats and engines, the scenes, URL and file handling |

Every macOS-only source file is wrapped in `#if os(macOS)`. The targets stay in the package on
Linux (where they compile to empty modules), so the package always resolves and the Linux
compiler still parses the Mac code. `scripts/mac-typecheck.py` then type-checks their bodies for
real against stub Apple frameworks (`scripts/mac-stubs/`, copied from Apple's docs; D-099).

The web half of the EPUB engine is TypeScript in `web/src/` (`bridge/*.ts`, pure and tested
under Node in `web/test/`; `glue.ts`, the WKWebView wiring, unverified on Linux). `pnpm build`
compiles it into `Sources/GlossReaderEPUB/Resources/reader/` next to `index.html`, `reader.css`
and `foliate/` (vendored foliate-js, pinned).

## 3. Domain model (GlossCore)

All identifiers are `Identifier<Entity>` values: 128-bit UUIDv7 (time-ordered, random
tail — no cross-device collisions), written as 26 lowercase Crockford base32 characters so
`gloss://` links stay short in plain markdown. IDs come from an injected `IDGenerator`, time
from an injected `TimeSource`.

| Entity | Key fields | Notes |
|---|---|---|
| `Document` | id, kind, title, author, contentHash, fileSize, originalFilename, coverHash?, metadata, addedAt, updatedAt, lastOpenedAt?, trash state | `kind` is an open `DocumentKind` struct (`"epub"`, `"pdf"`) |
| `ReadingPosition` | documentID, locator, progression, label, updatedAt | last position, per document |
| `Page` | id, documentID, parentID?, title, body, position, createdAt, updatedAt, trash state | `body` is the raw markdown string, never reserialised |
| `Highlight` | id, documentID, passage, color, createdAt, updatedAt | 5 colours; independent of links |
| `LinkTarget` | id, documentID, passage, createdAt, updatedAt, orphanedSince? | what `gloss://passage/<id>` points at |
| `PageReference` | pageID, kind (passage/page), referencedID | derived from page bodies on save |
| `TrashEntry` | id (= batch), kind, entityID, documentID?, title, trashedAt | one row per user-visible trash item |
| `Setting` | key, JSON value, updatedAt | typed keys (`SettingKey<Value>`) |

A **passage** (`Passage`) is `{ locator, quote, label, progression }`:

- `Locator { scheme, value }` is opaque. Only the engine that created it interprets it
  (`epubcfi` from foliate-js, `pdf` from the PDFKit engine). Stored files never change, so
  locators stay valid.
- `quote` and `label` ("chapter 3", "page 12") are captured at creation so hover popovers,
  the CLI and export never need an engine.
- `progression` (0…1) orders passages within a book without parsing locators.

### Highlights versus link targets

They are separate tables with no foreign key between them. Deleting a highlight never
touches link targets. Link targets are reference-counted through `PageReference`:

- Saving a page re-scans its body for `gloss://` links (`GlossMarkdown.LinkScanner`) and
  replaces its references. A target that drops to zero references gets `orphanedSince`;
  one that is referenced again has it cleared. References from trashed pages still count.
- `LinkMaintenance.sweep()` deletes targets orphaned longer than a grace period (default
  7 days, so undo, cut-and-paste and trash restores keep working). Unreferenced targets
  never show markers, so the grace period is invisible.
- If a target is removed while pages still reference it (book purged from the trash, a
  future sync conflict), `LinkMaintenance` rewrites each referencing body, replacing
  `[label](gloss://passage/<id>)` with `label`. The line of text survives.

### `gloss://` URLs

| URL | Meaning |
|---|---|
| `gloss://passage/<targetID>` | a passage (resolves to its document and locator) |
| `gloss://page/<pageID>` | a notes page (subpage blocks and page links) |
| `gloss://book/<documentID>` | a document (open at last position) |

`GlossURL` parses and formats them. Linking to other pages by `@`/`[[` search later only needs
a new editor trigger that inserts `gloss://page/…` links, since page links already resolve.

### Page tree

- Each document has exactly one root page (created empty at import, titled with the
  document's title).
- The tree (`parentID`) is authoritative. A line in the parent consisting only of a link to
  a child page (`[title](gloss://page/<id>)`) marks where that child renders as a block row.
  Children with no such line are listed after the body ("more pages in here"), so deleting
  the line never orphans a page.
- Renaming a page rewrites the label of its block line(s) in the parent when the label still
  equals the old title, so plain-text readers see the current title.

### Trash

Trashable entities register a `TrashableEntityHandler` (open/closed): `DocumentTrashHandler`
and `PageTrashHandler` ship in v1. Rules (`TrashService`, fully unit-tested):

1. Trashing an entity creates one `TrashEntry`; the entity and every live descendant it
   cascades to (a document's pages; a page's subtree) are stamped with that entry as their
   batch. Items already in the trash keep their own entries.
2. The root page cannot be trashed on its own; trashing the book does that.
3. Restoring an entry restores its whole batch (a cascade restores together).
4. If a restored item's container is itself trashed (a parent page, or the document), that
   container's entry is restored too, recursively — a page restored under a trashed parent
   brings its ancestors back.
5. Expiry is `trashedAt + TTL`, with the TTL read from settings at sweep time (default
   30 days, `never` allowed), so changing the setting applies to everything in the trash.
6. Purging hard-deletes rows and records `tombstones` for future sync. Purging a document
   removes its blobs' last references (blobs are collected separately) and degrades links
   into it from other books.

### Ports (protocols at real seams)

| Port | Implementations | Purpose |
|---|---|---|
| `LibraryStore` (`read`/`write` with `ReadTransaction` / `WriteTransaction`) | `SQLiteLibraryStore`, `InMemoryLibraryStore` | atomic multi-entity work |
| `DocumentRepository`, `PageRepository`, `HighlightRepository`, `LinkTargetRepository`, `ReferenceRepository`, `TrashRepository`, `SettingsRepository`, `ReadingPositionRepository`, `FullTextIndex`, `CoverCache` | per store | per-entity persistence, exposed by transactions |
| `BlobStore` | `SQLiteBlobStore`, `InMemoryBlobStore` | immutable content-addressed bytes; can move out of SQLite later |
| `ChangeFeed` | SQLite change journal, in-memory | detect writes made by other processes |
| `LibraryBackup` | SQLite `VACUUM INTO` | consistent copies |
| `DocumentFormat` (+ capabilities `TextExtracting`, `CoverExtracting`, `TableOfContentsReading`) | `EPUBFormat`, `PDFFormat` | everything that varies by document kind on the import side |
| `SearchSource` | library, book text, notes | contextual search |
| `Exporter` | markdown, html | export |
| `TrashableEntityHandler` | documents, pages | trash cascade/restore/purge |
| `SlashCommand` (GlossNotes) | page, headings, lists, quote, code, divider | slash menu |
| `BlockParser`, `InlineParser`, `StylingRule` (GlossMarkdown) | headings, lists, tasks, quotes, code, emphasis, links | extensible markdown |
| `ReaderDriving` (GlossReaderBridge) + capabilities (`ReflowableAppearanceApplying`) | `EPUBBridgeDriver` (foliate), PDFKit driver (Mac) | reading |

Services: `ImportService`, `LibraryService`, `PageService`, `HighlightService`,
`LinkService`, `LinkMaintenance`, `TrashService`, `SearchService`, `SettingsService`,
`ExportService` (GlossExport). Pure helpers: `GlossURL`, `NavigationHistory`,
`SearchScopeResolver`, `MatchFinder`.

## 4. Storage (GlossStore)

- One SQLite file: `~/Library/Application Support/gloss/library.sqlite` on macOS,
  `$XDG_DATA_HOME/gloss/library.sqlite` on Linux, overridable with `--library` / `GLOSS_LIBRARY`.
- GRDB `DatabasePool` in WAL mode with a busy timeout, so the app and the CLI can use the
  file at the same time.
- Tables: `documents`, `blobs` (content-addressed by SHA-256, immutable), `pages`,
  `highlights`, `link_targets`, `reading_positions`, `trash_entries`, `settings`,
  `tombstones`, `changes` (journal), and the derived, rebuildable, never-synced tables
  `page_refs`, `fts_entries` + `fts` (FTS5), `derived_covers`.
- Full-text search: one FTS5 table (`title`, `body`, `unicode61 remove_diacritics 2`) joined by
  rowid to `fts_entries(corpus, owner, document_id, locator, label)`. A corpus is a string
  (`notes`, `book-text`, `library`), so a new searchable source adds a corpus and an indexer,
  never a schema change. Queries are built by `FTSQueryBuilder` (prefix-matched tokens).
- Change journal: every write appends `(entity, id, origin)` rows; another process polls the
  journal to refresh (the app polls once a second).
- Backup: `VACUUM INTO` gives a consistent, compacted copy.

## 5. Formats and import

`ImportService.import(fileAt:)`: read bytes → `FormatRegistry.detect` (magic bytes, then
extension) → SHA-256 → duplicate check (offer the existing document) → `BlobStore.put` →
`format.readMetadata` → document row + empty root page → text extraction into the
`book-text` corpus → cover extraction into `derived_covers`. Progress is reported through an
`AsyncStream<ImportProgress>`; the work runs off the main actor.

- `GlossEPUB`: `META-INF/container.xml` → OPF (metadata, manifest, spine, cover) → nav
  document or NCX for the TOC → per-spine-item text with section locators.
- `GlossPDF`: a small, tolerant PDF reader in pure Swift: object scan (including object
  streams), `Info` metadata, page tree, content-stream text with ToUnicode/simple encodings.
  It feeds search and metadata on every platform; rendering is PDFKit's job on the Mac.
- Covers: EPUB covers come from the file; PDFs get a first-page render from the app's
  PDFKit `CoverExtracting` implementation; otherwise the UI draws a generated cover from
  title and author (`CoverStyle` picks colours deterministically).

## 6. Search

`SearchScope` is semantic: `.library`, `.allNotes`, `.document(id, facets: {text, notes})`.
`SearchScopeResolver` derives the options and the default from the context:

| Context | Options (default first) |
|---|---|
| home | library, all notes |
| reader only | this book's text, this book's notes, all notes, library |
| notes only | this book's notes, this book's text, all notes, library |
| split view | this book (text + notes), this book's text, this book's notes, all notes, library |

Each registered `SearchSource` decides whether it takes part in a scope and returns hits in
its group (notes, book text, library). Hits carry a destination (`page` + match range,
`book text` + locator + match text, `document`) so selecting one jumps there and highlights
the hit.

## 7. Notes editor

- Buffer = the raw markdown string. Styling is presentation only.
- `GlossMarkdown` tokenizes into blocks and inlines with UTF-16 ranges (so they map directly
  onto `NSRange`). `StylingRule`s turn the tree into `StyleSpan`s with semantic roles
  (`heading(1)`, `strong`, `syntax`, `passageLink`, …). `NotesTheme` (GlossNotes) maps roles to
  semantic `TextStyle`s on layers and flattens overlapping spans into `StyledRun`s;
  `StyledRunDiff` finds what a selection move changed. The Mac editor only turns a run's style into
  attributes (system fonts and colours). Syntax spans belong to an element; the editor dims syntax
  everywhere and shows it at full strength for the element under the cursor
  (`SyntaxReveal`).
- Format bar and shortcuts call `MarkdownEditCommand`s that return `TextEdit`s plus a new
  selection; the editor applies them through `NSTextView`'s change APIs so undo works.
- Slash menu: `SlashTrigger` finds `/query` at the cursor; `SlashCommandRegistry` ranks
  commands; `/page` creates a child page and inserts its block line.
- Subpage blocks: `SubpageBlocks` finds block lines; the editor draws them as rows (icon +
  live title) through a TextKit 2 layout fragment, without touching the text.
- Linking: `LinkGesture` knows whether "link to passage" is available (both sides selected)
  and produces the wrapping edit; `QuoteInsertion` builds `> quote [↗](gloss://passage/…)`.

## 8. Reading engines (macOS)

- `ReadingEngine` (GlossReaderKit) creates a `ReaderSession` for a document: a view plus the
  `ReaderDriving` commands (go to locator, show highlights, show markers, find, clear
  selection). Capability protocols (`ReflowableAppearanceApplying`, `FlowSwitching`) exist
  only on engines that support them. `ReadingEngineRegistry` maps `DocumentKind` → engine.
- EPUB: foliate-js (pinned commit, see `Resources/reader/foliate/VENDORED.md`) in a
  `WKWebView` with a non-persistent data store. A `WKURLSchemeHandler` serves the reader
  page, scripts and the book bytes (`gloss-reader://app/book/<id>`) straight from the
  `BlobStore`. Settings flow from the database into JS as bridge commands.
- PDF: `PDFView` over an in-memory `PDFDocument`. Highlights and link markers are drawn by a
  `PDFPageOverlayViewProvider`, never written into the file.
- Reader events (`relocated`, `selection`, `markerActivated`, …) and commands share one JSON
  protocol (`GlossReaderBridge` in Swift, `web/src/bridge/protocol.ts` in TypeScript) with shared fixtures
  under `Tests/Fixtures/bridge/` tested on both sides.

## 9. CLI

`GlossCLI` holds the commands (swift-argument-parser) and knows only the core, export, markdown
and terminal modules. `Sources/gloss/main.swift` is the composition root: SQLite store, EPUB and
PDF formats, `/usr/bin/open`, `$VISUAL`/`$EDITOR`. Commands read their environment (services,
output, stdin, opener, editor, clock) from a task-local `CLIEnvironment`, so tests run them
in-process against the in-memory store (`Tests/GlossCLITests`) and `scripts/cli-smoke.sh` runs the
real binary against real SQLite, EPUB and PDF files with concurrent writers.

```
gloss import <files or folders…>        gloss search <words…> [--book b] [--in library|notes|text|everything]
gloss list [--sort …] [--shelf …]       gloss export <book|page> [--format markdown|html] [--page-only] [-o path]
gloss book show|edit|trash <book>       gloss open <book|page|gloss://…>
gloss pages <book>                      gloss trash [list] | restore | purge | empty | keep <days|forever>
gloss read <page> [--raw|--rendered]    gloss backup <file or folder>
gloss page add|write|edit|rename|trash  gloss reindex
gloss highlights [list|delete]          gloss where
```

Every command takes `--json` (stable shapes in `JSONModels.swift`), `--library` and `--no-color`.
Output follows `NO_COLOR`/`CLICOLOR_FORCE` and drops colour and status lines when piped.

## 10. App layer (macOS)

- One main `WindowGroup` plus "open in new window"; a `Settings` scene.
- `WorkspaceModel` (GlossAppModel) holds the split layout (global), the open document/page,
  a `NavigationHistory` per pane (⌘[ / ⌘]) and the source list's selection, which decides the
  detail column (D-101). `BookSidebarModel` lists the open book's highlights and page outline;
  `AppModel.select` turns a click into navigation.
- `ExternalChangeMonitor` polls the change journal and refreshes models.
- `gloss://` URLs from other apps or `gloss open` route through `URLRouter`.
- **System components first** (D-019). `NavigationSplitView` with a source-list sidebar, a
  standard toolbar with a search field and its scope menu, popovers for marker lists and selection
  commands, sheets for import conflicts and document details, the standard `Settings` scene, and
  menu commands with standard shortcuts (D-070, D-071). Custom pieces (format bar, slash menu, link
  chips, subpage rows) use system materials (`.regularMaterial`/`NSVisualEffectView`), the system
  font, SF Symbols, standard animations and full VoiceOver labels.
- macOS only (D-018): Mac modules use AppKit and SwiftUI directly, with no platform abstraction.

## 11. Milestones

| # | Milestone | Scope | Where |
|---|---|---|---|
| 0 | foundation | repo, docs, package skeleton, GRDB/FTS5 spike, `scripts/check.sh` | Linux |
| 1 | core domain | IDs/time, entities, ports, in-memory store, `GlossURL`, navigation history | Linux |
| 2 | markdown | tokenizer, styling rules, edit commands, link scanning/rewriting | Linux |
| 3 | core services | import pipeline, library, pages/tree, highlights, links + maintenance, trash, settings, search service + scopes | Linux |
| 4 | sqlite store | schema, repositories, blobs, FTS, change journal, backup, multi-process tests | Linux |
| 5 | formats | archive, EPUB, PDF metadata/text/cover, format registry wiring | Linux |
| 6 | export + notes logic | exporters; slash commands, format commands, subpage blocks, link gesture, quote insertion | Linux |
| 7 | cli | every command, styled output, JSON output, tests | Linux |
| 8 | reader bridge + app model | vendored foliate, JS bridge + Node tests, Swift bridge types, appearance CSS, app view state | Linux |
| 9 | mac: epub from the database | app shell, composition root, scheme handler, foliate reader (risk #1) | Mac |
| 10 | mac: editor | TextKit 2 editor, live styling, format bar, slash menu, subpage rows (risk #3) | Mac |
| 11 | mac: linking | selection popover, link gesture, add to notes, markers, hover, split view, history (risk #2), PDF engine | Mac |
| 12 | mac: library & the rest | library grid, import UI, details, search UI, quick switcher, trash, export/print, backup, settings, external changes, URL handling | Mac |
| 13 | polish | copy review, README, LICENSE, handoff pass | both |
