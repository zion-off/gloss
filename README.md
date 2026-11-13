# gloss

gloss is a native macOS app for reading EPUBs and PDFs, with a free-form markdown notes page for
every book. Notes link to exact passages, and the book shows which passages your notes link to,
like footnotes you write yourself.

> **Status:** the core, storage, import, search, export and the `gloss` command line are built and
> tested on Linux. The Mac app (SwiftUI, TextKit 2, WKWebView, PDFKit) was written on Linux and
> type-checked against stub Apple frameworks, but it has **not been run on a Mac yet**.
> [`docs/MACOS_HANDOFF.md`](docs/MACOS_HANDOFF.md) is the checklist for its first sessions, riskiest
> parts first.

## What it does

- **Reading.** EPUBs in a web view running [foliate-js](https://github.com/johnfactotum/foliate-js)
  (vendored and pinned), PDFs in PDFKit. A table of contents, in-book search, progress (percent and
  pages left in the chapter, or "page n of N"), and gloss remembers where you stopped.
- **Highlights** in five colours, drawn as overlays (never written into the file), listed in the
  book's sidebar.
- **Notes** are one markdown page per book, styled as you type in a native TextKit 2 editor, with a
  floating format bar, a slash menu, task lists and subpages (shown as rows; breadcrumbs lead back
  up).
- **Links to passages** are plain markdown links with a `gloss://` URL. Select words in your notes,
  select a passage in the book, press ⌘K. The passage gets a marker; hovering either end previews the
  other, clicking follows it. Links can cross books, and each pane has back and forward (⌘[ ⌘]).
- **Split view** with the reader and the notes side by side, or either one alone.
- **Library** of covers (from the file, or generated from the title and author) with progress, a
  recently read shelf, filters and sorting. Import by drag and drop, File › import…, or by
  double-clicking a file in Finder; duplicates are recognised by content.
- **Search** with a scope menu that knows where you are: the library, this book's text, this
  book's notes or all notes, with grouped results that jump to the hit. Open quickly (⇧⌘O) goes
  to any book or page.
- **Trash** for books and pages, with undo and a retention period you choose (30 days by default,
  or forever).
- **Export** a book's notes, a page or a page with its subpages as markdown, or print to PDF.
- **One library file.** Everything (books, covers, notes, highlights, settings) lives in one SQLite
  file in `~/Library/Application Support/gloss/`, ready for a future sync: globally unique ids,
  change timestamps, soft deletes and content-addressed file storage. "back up library…" makes a
  consistent copy.

## The `gloss` command

Anything the app can do, scripts can do too. The app and the command share the library safely, and
the app picks up changes made from the terminal.

```sh
gloss import ~/Books                        # files or whole folders
gloss ls                                    # your library
gloss pages "moby dick"                     # a book's notes pages, as a tree
gloss read "moby dick"                      # a page, rendered (raw markdown when piped)
gloss page write "moby dick" -- '- call me ishmael'
gloss page add "moby dick" "the whale"      # a subpage
gloss search whiteness --book "moby dick"   # this book's text and notes
gloss export "moby dick" --output notes.md  # subpages become nested headings
gloss open gloss://page/<id>                # jump there in the app
gloss trash restore <id>                    # and whatever it was inside
gloss backup ~/Desktop                      # a consistent copy of the library
```

Books and pages are named by title, by id (or the short id gloss prints), or by a `gloss://` link.
Every command takes `--json`, and `--library` (or `GLOSS_LIBRARY`) points at another library file.
`gloss help <command>` explains the rest.

## Building

You need Swift 6.1 or later. The app needs macOS 14 or later; everything else also builds on
Linux. On a Mac, use Xcode 16.3 or later; the web view needs Node 22 with pnpm
(`corepack enable` picks up the pinned version).

```sh
swift build                   # everything (on Linux the Mac targets build as stubs; on a Mac, for real)
swift test                    # the portable suites (they run on macOS too)
scripts/check.sh              # what must pass before a commit: build with zero warnings, tests,
                              # the Mac type-check (on Linux; a Mac build needs no stubs),
                              # the cli smoke test, the web bridge tests
scripts/run-mac.sh            # on a Mac: builds build/gloss.app (development only) and opens it
```

The reader's web side is TypeScript, managed with pnpm (Node 22):

```sh
cd web && pnpm install --frozen-lockfile && pnpm test
```

## How it fits together

The core is plain Swift services over abstract ports; the command line and the app are thin
clients that wire concrete pieces (the SQLite store, the EPUB and PDF formats, the reading
engines) at their own composition roots. Adding a document format, a search source, an exporter
or a slash command means adding something and registering it.

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — modules, data model, seams, milestones
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — why things are the way they are
- [`docs/READER_BRIDGE.md`](docs/READER_BRIDGE.md) — the reading engine boundary and the web bridge
- [`docs/MAC_API_NOTES.md`](docs/MAC_API_NOTES.md) — the Apple APIs used, as documented
- [`docs/MACOS_HANDOFF.md`](docs/MACOS_HANDOFF.md) — what still needs a Mac to verify
- [`docs/REVIEWS.md`](docs/REVIEWS.md) — independent review findings and their fixes
- [`CLAUDE.md`](CLAUDE.md) — the working agreement for anyone changing the code

## License

[MIT](LICENSE). Third-party code keeps its own license:
[foliate-js](https://github.com/johnfactotum/foliate-js) (MIT, vendored with its license in
`Sources/GlossReaderEPUB/Resources/reader/foliate/`), [GRDB](https://github.com/groue/GRDB.swift)
(MIT), [swift-crypto](https://github.com/apple/swift-crypto) and
[swift-argument-parser](https://github.com/apple/swift-argument-parser) (Apache 2.0). ZIP files are
read by gloss's own code over the system's zlib.
