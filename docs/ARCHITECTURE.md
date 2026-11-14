# gloss architecture

A one-page map. The code is the source of truth; this says where things live and how they fit.

## Shape

The core is plain Swift services over abstract ports (`GlossCore`). The CLI (`Sources/gloss`) and
the app (`Sources/GlossMac`) are thin clients over the same services; each wires its concrete
pieces (SQLite store, EPUB and PDF formats, exporters, and in the app the reading engines) at its
own composition root (`main.swift`, `AppRoot.swift`). Logic lives in unit-tested modules; the
macOS-only modules (SwiftUI, TextKit 2, WKWebView, PDFKit) render state and forward events, and
their sources sit inside `#if os(macOS)`.

## Modules

Portable (no UI frameworks):

| Module | For |
|---|---|
| `GlossMarkdown` | block/inline parsing, styling rules, text edits, `gloss://` link scanning |
| `GlossCore` | the domain: entities, ports, services, `GlossURL`, quote anchors |
| `GlossStore` | SQLite (GRDB): schema, repositories, FTS5 search, blobs, change journal |
| `GlossArchive` | ZIP reading and inflate over the system zlib (`CZlib`) |
| `GlossEPUB`, `GlossPDF` | one per format: metadata, covers, text extraction, locators |
| `GlossExport` | exporters (markdown, html) |
| `GlossNotes` | notes-editor logic: styling theme, format commands, slash menu, subpage blocks, link gesture |
| `GlossReaderBridge` | engine-neutral reader boundary (`ReaderDriving`), the foliate bridge types, appearance CSS, `gloss-reader://` routing |
| `GlossReaderPDFSupport` | PDF reader logic that needs no PDFKit |
| `GlossAppModel` | observable app state: library, workspace, navigation, search, trash, reader controller |
| `GlossTerminal`, `GlossCLI` | terminal styling; the commands |
| `GlossMemoryStore`, `GlossTestSupport` | in-memory store and fixtures for tests |

macOS-only: `GlossReaderKit` (engine protocol and registry, host view), `GlossReaderEPUB`
(foliate-js in a `WKWebView`), `GlossReaderPDF` (PDFKit with overlay highlights),
`GlossEditor` (TextKit 2 notes editor), `GlossUI` (SwiftUI scenes), `GlossMac` (app root).

Extension points are protocols registered at the roots (`DocumentFormat` and its capabilities,
`SearchSource`, `Exporter`, `TrashableEntityHandler`, `SlashCommand`, markdown `BlockParser` /
`InlineParser` / `StylingRule`, `ReadingEngine`). `DocumentKind` is an open struct, not an enum.

## Data and storage

Entities (`Document`, `Page`, `Highlight`, `LinkTarget`, `ReadingPosition`, `TrashEntry`, settings)
have time-ordered UUIDv7 ids, written as short lowercase base32 so `gloss://` links stay readable.
Each book has one root page; subpages form a tree and appear in the parent as a link-only line.
Page bodies are raw markdown. A passage is `{locator, quote, label,
progression}`; the locator is opaque and only the engine that made it reads it. Highlights and
link targets are separate; saving a page re-derives its `gloss://` references, and targets nobody
links to are swept after a grace period. Trash is soft deletion with batch restore and a
retention setting; purging leaves tombstones.

Everything is one SQLite file (WAL, so the app and the CLI can share it): by default
`~/Library/Application Support/gloss/library.sqlite`, overridable with `--library` or
`GLOSS_LIBRARY`. Book bytes are content-addressed blobs in the same file. Search is one FTS5 table
keyed by corpus (notes, book text, library), so a new searchable source adds a corpus, not a
schema change. Every write appends to a change journal; the app polls it to pick up CLI writes.
Search tables and covers are derived and rebuildable (`gloss reindex`).

## Reader and web bridge

EPUBs render with vendored foliate-js (pinned, see `foliate/VENDORED.md`) in a `WKWebView` with a
non-persistent data store. A `WKURLSchemeHandler` serves the reader page and the book's bytes
(`gloss-reader://app/…`) from the blob store, so book data never travels through JS strings. The
web half is TypeScript in `web/src` (`bridge/*.ts` pure and tested under Node, `glue.ts` the
WebKit wiring); `pnpm build` compiles it into `Sources/GlossReaderEPUB/Resources/reader/`.
PDFs use `PDFView`; highlights and markers are overlays, never written into the file.

Swift and JS speak one JSON envelope protocol, `{ v, type, payload }`, defined in
`web/src/bridge/protocol.ts` and `GlossReaderBridge`; both test suites load the same fixtures in
`Tests/Fixtures/bridge/`. Commands go Swift to JS through `callAsyncJavaScript`; events come back
as JSON text through the `gloss` script message handler. Opens are numbered (`openID`) so
`ReaderController` drops events from a replaced book. A book's scripts must never run (its
sections live in `blob:` documents that could reach the scheme handler): the page CSP, a veto in
the glue and `bridge/sanitize.ts` keep them out.

## Quote locators (`gloss link`)

The CLI has no engine to ask for a position, so formats that can extract text implement
`QuoteLocating` and pin a passage by its words instead: locator schemes `epub-quote` and
`pdf-quote` carry the section or page plus a `QuoteAnchor` (quote, context, occurrence). Readers
resolve the anchor against the text they actually show, then draw, jump and flash as for any
other passage. The CLI finds the words (`PassageFinder`), never guesses between several matches,
and writes through `LinkService`, so references, the index and the journal update and a running
app draws the marker within a second. The Swift and TypeScript resolvers share the cases in
`Tests/Fixtures/quotes/resolve.json`.

## App layer

The reader and notes panes move independently (a link changes the pane it points into), each with
its own back/forward history. `ExternalChangeMonitor` refreshes models from the change journal.
`gloss://` URLs and files opened from Finder share one door, `AppModel.open(url:)`.

## Releases and updates

`scripts/release.sh` builds a universal `gloss.app` (the CLI in `Contents/Helpers`, Sparkle in
`Contents/Frameworks`), a dmg and the zip Sparkle updates from. Only `GlossMac` links Sparkle, and
only release bundles carry its feed URL and public key, so development builds have no updater.
`.github/workflows/release.yml` publishes a release when a pull request labelled `release` is
merged, with an appcast signed by the key in the `SPARKLE_PRIVATE_KEY` secret.
