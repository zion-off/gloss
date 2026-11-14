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
- **D-013 No ZIP dependency: own central-directory reader over system zlib (`CZlib`).** ZIPFoundation
  was evaluated first, but its Linux inflate loop (`repeat … while result != Z_STREAM_END` in
  `Data+Compression.swift`, 0.9.20) never terminates on truncated input, so one corrupt EPUB or PDF
  stream could hang an import. Reading a ZIP's central directory (stored/deflate, ZIP64) is ~200
  lines; `Inflate` is bounded (zip-bomb limit) and always terminates. zlib ships with macOS and every
  Linux distribution, so this adds no dependency.
- **D-014 foliate-js, vendored at a pinned commit** — required by the brief; vendored (not fetched)
  so CFI resolution can never change under existing notes. The PDF.js vendor folder is dropped
  because PDFs use PDFKit.
- **D-015 jsdom as a test-only dev dependency** — lets the bridge tests drive the real vendored
  `epubcfi.js` against a DOM under Node; it never ships in the app.
- **D-060 The bridge is one JSON protocol with shared fixtures.** Commands and events are one
  envelope each (`{v, type, payload}`), decoded by a tagged-union enum per side; unknown types throw
  rather than degrade silently, so version skew is loud. `Tests/Fixtures/bridge/` is the contract:
  the Node suite and the Swift suite both decode every fixture and round-trip it.
- **D-061 Reader settings live in the settings store as one JSON blob** (`reader.settings`), a
  Codable `ReaderSettings`. One key keeps load/save atomic; the settings UI edits the struct.
- **D-062 The bridge carries presentation, the store carries truth.** Events map into core values
  (`ReaderEventMapping`): selections become `Passage`s, relocations become `ReadingPosition`s, and
  the annotation payload is derived from `[Highlight]` and `[LinkedPassage]` — the Mac layer never
  interprets raw JSON.
- **D-018 The app is macOS-only (user requirement).** No other app targets, no other platforms in
  `Package.swift`, and no UI abstraction for other platforms. Portable modules exist to be built
  and tested on Linux and reused later. The Linux-buildable logic modules (markdown, notes, reader
  bridge, app model, terminal) count as test seams under "keep Mac-only code thin", not as a
  cross-platform UI layer, so they stay. iCloud sync stays possible at the data layer (tombstones,
  change journal, separate blob store).
- **D-019 Unspecified UI follows first-party Apple apps and the HIG (user requirement).** System
  components first, no custom chrome, modes or banners, contextual commands, menus, popovers and
  sheets. Custom pieces (format bar, slash menu, link chips) use system materials, fonts, SF Symbols
  and animations. Plan items that are specified still apply but are implemented the Apple way: the
  specified undo toast also registers with the window's `UndoManager` so Edit › Undo and ⌘Z work.
- **D-070 Formatting shortcuts follow Apple Notes' Format menu.** ⌘B, ⌘I, ⇧⌘H heading,
  ⇧⌘7 bulleted list, ⌘' block quote, ⇧⌘M monospaced. The first draft used ⇧⌘Q for quote, which
  is the system-wide Log Out shortcut. ⌘K is the plan's "link to passage", so the plain web link is
  ⇧⌘K. A test keeps format shortcuts away from system, standard-menu and gloss-reserved shortcuts.
- **D-071 The quick switcher is ⇧⌘O ("open quickly"), after Xcode's Open Quickly.** The plan's
  "⌘P style" names the interaction, not the key: ⌘P is Print (and "export as PDF via print" needs
  it), and ⌘O is File › Open in every Mac app.
- **D-072 Short ids are the last 8 characters of an id.** UUIDv7 ids start with a timestamp, so
  prefixes of things created in the same second collide; the tail is random. References accept a
  4+ character start or end of an id, a full id, a `gloss://` link or a title.
- **D-073 Global CLI options go after the subcommand** (`gloss list --json`). ArgumentParser's
  `@OptionGroup` in every leaf command is its standard way to share options; `@ParentCommand` only
  reaches one level up, and `gloss trash restore` is two deep. `GLOSS_LIBRARY` covers scripts that
  want to set the library once.
- **D-074 `gloss read` prints raw markdown when stdout is piped and renders on a terminal**
  (`--raw`/`--rendered` force either), so `gloss read x > notes.md` round-trips.
- **D-075 ArgumentParser's built-in help and error headers stay as the library prints them**
  ("OVERVIEW", "Error:"). They aren't configurable; all of gloss's own copy is lowercase.
- **D-076 Deleting for good needs `--yes`, or a "y" at a prompt on a terminal.** Without a terminal
  to ask on, `trash purge`/`trash empty` refuse (exit 64) rather than guess.
- **D-077 `gloss open` hands the link to `/usr/bin/open` on macOS and prints it elsewhere** (exit 0),
  so scripts can still capture `gloss://` links on Linux.
- **D-078 Exit codes: 0 success, 1 failure (including partial import failures), 64 wrong usage**,
  matching ArgumentParser's validation failures (EX_USAGE).
- **D-017 Web code is TypeScript with pnpm (user requirement).** JavaScript only where TypeScript is
  impossible: vendored foliate-js (must stay byte-identical, D-014) and `tsc` output for the web view.
  The output is committed rather than built by a SwiftPM plugin so `swift build` never needs Node,
  and `pnpm check-build` catches stale output. Tests run the `.ts` sources directly under Node 22's
  type stripping, so the sources use erasable syntax only (`erasableSyntaxOnly`).
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
- **D-033 New link targets start orphaned.** A target created for "link to passage" counts as
  referenced only once a saved page links to it, so abandoned gestures are swept like any orphan.
- **D-034 Renaming a book renames its root page only if the root still had the book's old title.**
  Same rule as block-line labels: follow along unless the user customised it.
- **D-035 Purging a page degrades links to it, like passages.** Page links (block lines included)
  become plain text, so a purged page never leaves a dead `gloss://` link behind.
- **D-036 Purging a book also purges its pages that were trashed separately, entries included.**
  Nothing may survive whose document is gone.
- **D-037 Search hides trashed books and pages at query time** instead of removing their index
  entries, so restoring needs no re-indexing.
- **D-038 Library title/author sorting ignores case, accents and a leading "the/a/an"; empty values
  sort last.** Matches how Apple Books and Finder present titles.
- **D-039 `gloss page add` places the new subpage at the end of the parent's body.** The editor
  inserts the block line at the caret itself; outside the editor the end of the page is the only
  sensible place, and an unplaced page would still render after the body.

## Linking without the app (`gloss link`)

- **D-190 The CLI pins passages by their words, not by computed CFIs or PDFKit offsets.** Formats
  that can (`QuoteLocating`, a capability next to `TextExtracting`) mint `epub-quote` / `pdf-quote`
  locators: section or page, plus a `QuoteAnchor` (the quote, 32 characters of context either side,
  and which occurrence it is). The readers resolve them at runtime against the text they show — the
  glue in the section document it parses like foliate's search, then the range's CFI; the PDFKit
  engine in `PDFPage.string`, then a `PDFPassageLocator` — and from there marker, jump, flash and the
  marker click are the existing paths. Rejected: computing real CFIs in Swift. The DOM foliate numbers
  is WebKit's parse of the sanitized markup (XHTML vs HTML parsing, implicit elements, entities,
  whitespace nodes, removed scripts), so a Swift CFI would be exact only for some books and wrong
  silently for others (a marker on the wrong words); a quote either resolves to the right words or
  draws nothing. PDFKit's string offsets can't be reproduced off PDFKit at all. One scheme design for
  both formats; the schemes stay opaque to the core (open/closed: no switching on kind).
- **D-191 `gloss link` never guesses.** Several matches on either side list every candidate (label,
  context with the match marked, `--nth N` / `--text-nth N` and an exact `--match` / `--text-offset`)
  and exit 64, in `--json` too (`{"error", "side", "candidates"}`); only with stdin and stdout both
  terminals (and no `--json`) does it ask which one. An exact place never prompts: `--match
  scheme:value@start-end` (a text chunk's locator and a UTF-16 range of its extracted text, printed by
  `--list`/`--json`), `--section N`/`--page N` with `--offset`, `--text-offset` in the body as
  `gloss read --raw` prints it. Offsets are UTF-16 because the whole codebase is (`NSRange`, the
  editor, `MarkdownText`). With an exact place, `--quote`/`--text` verify it (`--force` skips).
  `--match scheme:value` without a range scopes the search to one chunk, so a `gloss search --json`
  hit's locator can be pasted in.
- **D-192 Matching: whole words, spacing ignored, case optional; resolving: context first.** The CLI
  matches folded text (curly quotes, dashes, ligatures and soft hyphens folded; whitespace runs equal
  one space; `-i` folds case) on word edges, so "the" never matches inside "mother". The stored
  occurrence counts whitespace-*insensitive*, case-sensitive matches, the same way the readers count,
  because the extractor and the DOM disagree about spaces between blocks. Readers pick the match
  whose context agrees most, then the stored occurrence, then the nearest; then a case-insensitive
  match; then the quote's first and last 16 characters with agreeing context (an image's alt text in
  the middle); otherwise nothing is drawn and a jump lands at the section's start. Swift
  (`FoldedText`, `QuoteAnchor`) and TypeScript (`bridge/quote.ts`) share `Tests/Fixtures/quotes/`.
- **D-193 Linking twice changes nothing; no write-back.** The same occurrence makes the same locator
  JSON (sorted keys), so D-026 reuses its target; words already linked to it are left alone; a quote
  line is not added twice. Words inside another link re-point it, as ⌘K does, and the output says so.
  A CLI link and a GUI link to the same words are two targets (different locators) drawn as one
  underline whose popover lists both. Readers don't upgrade quote locators to CFIs/PDF locators:
  writing from the reader would race edits and sync for a saving of one parse per section per open.
- **D-194 Scripts written without spaces have no word edges.** Whole-word matching (D-192) looked
  for letters on both sides of a match, which is every position in a Chinese, Japanese or Thai
  sentence, so those quotes never matched. `FoldedText.isWholeWords` now treats Han, kana, Bopomofo,
  Thai, Lao, Tibetan, Myanmar and Khmer characters as non-word characters: a match next to them is
  always at an edge (Latin next to Han still checks its own side). Only the CLI checks word edges;
  the readers' resolver (`bridge/quote.ts`) matches anywhere, so the TypeScript twin needed no
  change, only the shared fixture cases (Chinese, kana that decompose, Thai) that keep folding in step.
- **D-195 A repeated `--text-offset` finds the link its first run made.** The "[" a link inserts
  shifts the words one character on, so the same offsets no longer named them. `NotesTextFinder.
  match(wrappedAt:)` accepts a range that is exactly one character before a link's label (a link
  starting where the range starts, label = range + 1): such a range starts on a link's "[" and could
  never be linked as it is, so it can't mean anything else. The outcome is the usual one: same
  target says "already links", another target re-points it.

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
- **D-141 (supersedes D-055) Markdown syntax is collapsed, and shows when the cursor touches its
  element.** Marks (`**`, `#`, backticks, link brackets) and link destinations keep their characters
  but get a ~0pt font and a clear colour (`TextStyle.collapsed`); an element the selection touches
  shows them again, dimmed. Reason: the first Mac run showed asterisks and `gloss://passage/…` urls
  around every styled word, which no first-party notes app does. Caret movement stays sane because the
  element reveals as soon as the caret reaches it. Also: a caret never rests inside a subpage row's
  hidden markdown (it snaps to an end of the line).
- **D-056 Bold/italic with an empty selection wraps the word under the caret,** or inserts an empty
  pair between words — the common behaviour of native markdown editors.
- **D-057 Text gloss writes into notes is escaped minimally** (`\ * [ ] ~ \``, word-boundary `_`,
  tag-like `<`, leading block markers) so quotes stay readable as plain text.

## Process notes

- **P-006 The review-7 fix branch was rebased before it landed** (two commits reordered so each
  builds alone). `docs/REVIEWS.md` first cited the seven pre-rebase hashes (`4bd1eb3`, `7f8a6ab`,
  `4eb21ce`, `cc7fb40`, `ac48b22`, `0fdcf8c`, `0c6eacf`), which dangle outside history; review 8
  caught them and they are re-pointed at the commits that landed (`1beb0d7`, `50e39d5`, `6a03d57`,
  `e2d4f6d`, `931e7ce`, `2acdd4f`, `ba71313`). Landed history was not rewritten (commit policy).
- **P-005 Decision numbers D-103…D-109 and D-129 were allocated and never used** (worker slices
  that came in under budget). They are gaps, not lost entries; the next new decision takes D-140.
- **P-001 Five milestone-1 commits do not build on their own** (`3903e20`, `f350c16`, `f4cce6a`,
  `0078ce7`, `d1a1c5c`, verified with `scripts/verify-commits.sh`): they were split from one green
  check. History is not rewritten (commit policy). Since then each slice is checked before its own
  commit and ranges are verified with `scripts/verify-commits.sh`.
- **P-002 `ce7a2c2` has no confirmed author.** It appeared at 21:10:52 UTC with the repo identity,
  holding exactly the lead's finished GlossNotes slice (same 7 files, tests green). The bridge agent
  confirmed it ran no git write commands; the subject's style matches the lead's own, so a retried
  lead command is the likeliest source. Its content is correct, so it stays (no history rewriting). `scripts/check.sh` also runs the JS tests once
  `web/` exists, so Swift slices committed while the bridge work is in progress are checked with
  `swift build --build-tests && swift test` instead.

- **P-003 Three commits landed while `scripts/check.sh` failed:** `1649cd3`, `df13e97` (a flaky
  layout-persistence test, a real race) and `2fd6047` (same flake). The gate was
  `scripts/check.sh | tail -n 1 && git commit`, where the pipe hides the check's exit status. The
  race is fixed in `3ea4ea3`/`d76dcf2`, every timing-based test now waits deterministically, and
  CLAUDE.md forbids piping the check when gating a commit.

- **P-004 `45bf246` and `7579d9e` don't build alone.** A test file holding tests for two slices
  was staged whole into the first; the type its second test needs only arrives in `46d8614`. Caught
  by `scripts/verify-commits.sh`; history is not rewritten. Edits are now staged slice by slice.

## Formats (GlossPDF)

- **D-063 The PDF reader scans the whole file for `N G obj` bodies instead of following xref
  offsets.** Broken xref tables are the most common real-world PDF defect. Headers are found by a
  bounded byte matcher (at most ~150 bytes read per position, no allocation), so the search is
  linear; definitions later in the file win, which is incremental-update semantics. That holds
  across object streams too: a compressed member only replaces a definition that comes earlier in
  the file. Trailer candidates (`trailer` dictionaries and xref streams) are sorted by file
  position, and the last one with `/Root` or `/Info` wins.
- **D-064 Every lexer that parses document bodies shares one scan budget (16 bytes per input
  byte + 1 MB).** Tolerant parsing re-reads input after failures, and review 1 found an
  unterminated string made that quadratic (a 32 KB file took 37 s). The budget makes the worst case
  linear by construction; legitimate files read each byte about once. Stream data is never lexed:
  `/Length` is trusted when `endstream` appears where it predicts, else gloss scans for `endstream`.
- **D-065 `GlossArchive.Inflate` is the only decompressor.** It is bounded and
  truncation-tolerant, so one corrupt stream can never hang an import; LZWDecode is treated as
  unsupported (nil) rather than reimplemented, since it is rare in the wild.
- **D-066 Encrypted PDFs return what is readable without decryption and no text chunks.** The
  page tree and resource names are unencrypted, so the page count still comes out; strings and
  streams are not, so title/author/text are skipped rather than emitted as garbage. Only
  non-PDF data throws.
- **D-067 Simple fonts decode through WinAnsi/MacRoman/Standard tables plus `/Differences`
  (AGL subset, `uniXXXX` names); Type0 through `/ToUnicode` CMaps.** With no usable mapping,
  printable bytes fall back to Latin-1 — wrong-but-readable beats nothing for search.
- **D-068 `PDFPassageLocator` is pure Codable JSON under the `pdf` scheme with a `v` field.**
  The Mac PDFKit engine can mint locators without GlossPDF present at runtime, and search
  chunks use a separate `pdf-page` scheme (plain page index) so the two never collide.
- **D-069 The test target adds `GlossArchive` beyond the brief's dependency list** so tests
  can compress streams with `Deflate.zlib`; `GlossTestSupport` alone does not re-export it.

## Reader engine boundary

- **D-079 Opens are numbered; book events count only after the matching `opened`** (review 3).
  Engine events carry no book identity, and foliate's debounced relocations and selections can
  land after the next book was asked for. `ReaderDriving.open` takes an `openID` the engine echoes
  in `.opened`; `ReaderController` drops book events in between and replies to replaced opens.
  Tagging every event envelope was the alternative; it needs the same JS discipline (nothing from a
  closed book after the next `opened`) and changes every payload.
- **D-080 Books switch in place in the same web view.** `open` closes the previous book first, and
  `close` blanks the reader (a trashed book). Reloading the page per book would also work but makes
  the Mac adapter own a reload choreography that can't be tested on Linux.
- **D-081 Reader events travel as JSON text** (`postMessage(JSON.stringify(envelope))`), and commands
  as JSON text parsed in the page, so both sides decode exactly what the other validated, with no
  WebKit object bridging (number/bool coercion, `NSNull`).
- **D-082 Book scripts are stopped three times over:** the page CSP, a veto on script resources and a
  sanitizer that strips script from every document before foliate makes it a `blob:` URL
  (docs/READER_BRIDGE.md, "Book scripts"). The CSP alone rests on WebKit inheriting it into `blob:`
  documents, which can't be checked off a Mac.
- **D-083 Engine events reach the controller through a per-session `ReaderEventInbox`**, one at a
  time in arrival order, because handling an event awaits engine commands and WebKit delivers
  messages synchronously.

## Mac app

- **D-084 `GlossMac` builds on Linux as a stub that prints one line.** An executable target can't be an
  empty module, and keeping it in the package (rather than adding it only on macOS in `Package.swift`)
  lets the Linux compiler parse every Mac source (D-002). The stub is not a Linux app (D-018).
- **D-085 Each window owns an `AppModel`; the services are shared.** `AppModel` is one window's state
  (one reader, one workspace), so a second window can't share it. Each window polls the change journal
  while it is open; the poll is one indexed query.
- **D-086 Milestone 9's window is a plain source list plus the reader.** The cover grid, import UI and
  the rest of the library are milestone 12; until then books come in with `gloss import`.
- **D-087 The development app bundle is `dev.gloss.app`, built by `scripts/run-mac.sh`.** SwiftPM's
  resource bundles go in `Contents/Resources`, where `ReaderBundle` looks before SwiftPM's own lookup,
  so the bundle can move without the build directory.
- **D-088 Reader errors name their open.** `error` events carry the `openID` of the failed `open`
  (null otherwise), so the controller can un-wedge exactly that open and ignore failures of opens a
  newer one replaced (review 4). The alternative — treating any failure during an open window as that
  open's — cancels the wrong open when a stale failure lands late.
- **D-089 The notes editor is a plain-text TextKit 2 view with storage-owned attributes.** The
  buffer is the raw markdown; `isRichText = false` keeps pasted text plain; the coordinator sets
  presentation attributes from `NotesTheme` runs. If plain-text mode turns out to refuse storage
  attributes on a Mac, switch to `true` and restrict pasteboard types instead (handoff).
- **D-090 A custom `NSTextLayoutFragment` is made for every paragraph.** Subpage rows need one,
  and returning the default drawing for ordinary paragraphs costs nothing measurable. The
  delegate is `nonisolated` with `MainActor.assumeIsolated` (TextKit lays out on the main thread);
  if that ever crashes, the rows snapshot needs a lock instead.
- **D-091 Model edits apply through `shouldChangeText` → `replaceCharacters` → `didChangeText`**,
  coalesced into one `TextEdit` per command, so undo records each as a single step. Page installs
  and external replaces clear the undo history: the old page's edits must never replay into the
  new one.
- **D-092 Reveals carry a token and the page they're for.** A marker click may open another page
  first; the editor applies the reveal once, on that page, clamped to the current text.
- **D-093 Refusing to switch pages offers keep/discard, with Escape meaning keep.** The editor
  keeps its unsaved text either way; "keep editing" puts the workspace back on the editor's page.
- **D-094 Overlay anchors cross the AppKit → SwiftUI coordinate boundary once**, in
  `OverlayGeometry` (GlossAppModel, Linux-tested): flip, clamp, above/below. The Mac layer only
  converts `NSRect` at the boundary.
- **D-095 The layout switches with ⌥⌘1/2/3, Preview-style** ("reader and notes", "reader only",
  "notes only" in the View menu, mirrored by a segmented toolbar control). No system or Edit-menu
  shortcut uses them; Preview uses the same ⌥⌘-number family for its sidebar modes.
- **D-096 The book shows a marker's notes on click, not hover.** Hovering in the web view would need
  a continuous pointer event over the bridge; Books shows notes on tap. Hover previews live where the
  pointer already is: on passage links in the notes. `ReaderController.hover(over:)` stays as the
  content source, now shared with the marker-choice popover's snippets.
- **D-097 The reader's engine session belongs to the window, not the pane**, so hiding the reader
  (notes only) and showing it again re-hosts the same view instead of reloading the book.
- **D-098 The reader shows one popover at a time**: a marker's notes, then a clicked highlight, then
  the selection's commands (`ReaderController.popover`). Dismissing the selection's popover clears
  the selection in the engine too.
- **D-099 The Mac modules are type-checked on Linux against stub Apple frameworks**
  (`scripts/mac-typecheck.py`, part of `check.sh`). Three reviews running found Mac code that could
  not compile (half-applied edits, a missing member, `guard let` on a name that didn't exist, a
  missing `try await`, an API that doesn't exist), and `mac-visibility.py` sees only type
  visibility. `scripts/mac-stubs/` declares just the slice of AppKit, SwiftUI, WebKit, PDFKit and
  UniformTypeIdentifiers gloss uses, each member copied from Apple's documentation JSON; the
  sources compile line for line with `#if os(macOS)` switched on. It proves names, labels, types,
  `try`/`await` and Swift 6 isolation against the stubs; not behaviour, and only as far as the stubs
  are faithful, so a member goes into a stub only after its docs page is checked.
- **D-100 Non-isolated Apple protocols are satisfied with `nonisolated` methods plus
  `MainActor.assumeIsolated`**, never isolated conformances (`@MainActor Protocol`): those need
  Swift 6.2 and the package declares tools 6.1. PDFKit and TextKit 2 call them on the main thread.
- **D-101 One source list, sectioned like Mail or Music.** "library" holds the shelves (all, books,
  pdfs: the brief's filters) and the trash; while a book is open, a section named for it holds its
  contents, highlights and notes pages (collapsible). The selection decides the detail column: the
  cover grid, the trash, or reader + notes. Opening a book selects its notes page, so the book's
  section always shows where you are; picking a shelf keeps the book open one click away. Rejected:
  Preview's sidebar that swaps its content by a menu (hides the library while reading) and a third
  column (too wide next to reader + notes).
- **D-102 Each pane moves on its own; a link changes the pane it points into** (brief 15: "following
  a cross-book link swaps the book pane", each pane with its own back and forward). A passage or book
  link in the notes swaps the reader; a page link, subpage row, breadcrumb, the outline or a marker
  click swaps the notes; each pane's back/forward moves only that pane. So the panes can show
  different books, which is what lets ⌘K make a cross-book link and lets a cross-book marker open its
  note without pulling the reader off the passage. Choosing a book (library, open quickly) still
  shows it with its notes, and a jump from outside the panes (a `gloss://` URL from another app or
  `gloss open`) brings the other pane along (`AppModel.open`, `bringingBook:`/`bringingNotes:`). A pane
  never sits empty beside a book. The source list's book section is the reader's book (contents,
  highlights); its notes outline is the notes pane's book, headed with that book's title when the two
  differ. Reader back/forward while the grid or the trash is the detail column moves the reader
  behind it and leaves the window where the user is — history never hijacks the window (review 7).
  Before this, every navigation dragged the other pane along, so the two always showed one book.
- **D-110 The library's covers are one Apple Books-style grid** (`LibraryGrid`, replacing the
  placeholder list): `LazyVGrid` of adaptive columns, each cell a cover with the kind badge
  (bottom-trailing, the format's own word via `FormatRegistry.badge`), a thin progress bar only
  once the book has been opened, then title and author. A single click opens the book; arrow-key
  selection is deliberately absent (Books opens on click; a selection ring would be new chrome).
- **D-111 The "recently read" shelf shows only on "all".** A filtered shelf means "show me this
  kind", and the row would repeat what the grid below already holds; with nothing recent the
  section is simply gone (no empty shelf-within-a-shelf).
- **D-112 The library sort is one persisted setting, and every window agrees within a second.**
  `LibraryModel` persists it through `services.settings` (chained writes, newest wins, like the
  layout in D-095); other windows pick it up in their existing one-second poll (`syncSort`),
  because the change journal can't carry it — all windows share one process origin, so the poll
  skips their own writes. A NotificationCenter fan-out was rejected: it leaks across parallel
  tests (each has its own store) and its object filtering isn't portable.
- **D-113 File › import… is ⇧⌘A, Apple Books' "add to library" shortcut**, placed after the
  (empty) import/export slot in the File menu. It is added to `FormatBar.reservedShortcuts` so
  no future format shortcut takes it; ⌘A (select all) stays untouched.
- **D-114 Import news is one alert, built in the portable model.** `ImportSummary` records what
  an import found (added, duplicates, failures) and writes the alert's title, message and
  "open it/open them" action; the view only presents it. Opening several duplicates opens each
  in turn, ending on the last — one code path, no per-row sheet.
- **D-115 A never-opened book shows no progress bar: absence is the "new" state.** A bar under
  the cover appears only once reading has started, so the empty state can't be mistaken for a
  bug; VoiceOver reads "not started yet" vs "n% read".
- **D-116 The generated cover's look is decided portably and never changes.** `GeneratedCoverStyle`
  (GlossAppModel) picks the tint from a fixed ten-colour palette by a stable FNV-1a hash of the
  document's id (ids never change, so no launch-to-launch or window-to-window drift), wraps the
  title to at most three 14-character lines with an ellipsis cut, and trims the author. The Mac
  view only draws it (serif title, white text on the tint).
- **D-117 The details sheet writes only what changed, and every pane refreshes after.**
  `DetailsDraft` trims, refuses an emptied title, and returns nil for unchanged fields so an
  untouched field never marks the document updated; `AppModel.refreshAfterDetailsEdit` then
  reloads the grid and cover cache, the workspace's document and page (window title, source
  list), the notes editor's page (its breadcrumbs now follow external changes too) and the
  book's sidebar tree.
- **D-118 The whole window is the import drop zone.** `dropDestination(for:)` is deprecated in
  macOS 27.3 (its replacement needs macOS 26), so the drop uses `onDrop(of: [UTType.fileURL])`
  with `NSItemProvider.loadObject(ofClass: URL.self)` — the current, non-deprecated API at the
  macOS 14 target. Folders and files both land in `LibraryModel.importFiles`, the single entry
  point the Finder and `gloss://` workers call too.
- **D-119 The import panel is an `NSOpenPanel`, not `.fileImporter`.** The brief needs multiple
  files *and folders*; fileImporter's documented behaviour for directories can't be confirmed,
  while `NSOpenPanel.canChooseDirectories` is explicit. It presents as a sheet on the key window
  (`beginSheetModal`), app-modal (`runModal`) if there is none, filtered to the registered
  formats' extensions via `UTType(filenameExtension:)` — never a hardcoded epub/pdf list.
- **D-120 Settings changes travel by `NotificationCenter`, not the change monitor.** Every window
  polls the journal for *other processes'* writes only (one `origin` per process), so the Settings
  window's saves would never reach open windows any other way. `NotificationCenter` with
  `queue: nil` delivers synchronously on the posting (main) thread — verified against
  swift-corelibs-foundation, so `MainActor.assumeIsolated` in the observer is safe on both
  platforms; the notification carries the new `ReaderSettings` in `userInfo`.
- **D-121 The Settings window is one form, not tabs.** The only tab API a macOS 14 target can
  use (`tabItem`) is deprecated in the newest SDK, and its replacement needs macOS 15; a
  "general"/"reading" form is the other Apple pattern (Safari's general pane).
- **D-122 Open EPUB sessions take reading-settings changes live, through the
  `ReflowableAppearanceApplying` capability the engines already had** (the bridge's
  `setAppearance` command). PDFs can't reflow, so they pick changes up at their next open;
  `AppRoot`'s `AppearanceSource` follows the same notification for sessions opened later.
- **D-123 The reading tab exposes theme, text size, line spacing, margins, flow and columns;
  `maxInlineSize` stays at its default.** The column-width knob is advanced plumbing Apple Books
  never shows either, and the struct keeps carrying it, so exposing it later is additive.
- **D-124 Backup file names live in one place, `LibraryBackupNaming` (GlossCore)**, so the cli's
  `gloss backup <folder>` and the app's save panel offer the same `gloss backup <date>.sqlite`
  without the CLI importing app code. The panel doesn't restrict content types (no system UTType
  for SQLite); gloss never overwrites a backup: the model pre-checks with a friendly message and
  the store refuses too (D-043's `VACUUM INTO`).
- **D-125 "back up library…" is a per-window flow (`BackupCommands`) reached from the File menu
  through a focused value**, like the window commands; the copy itself runs detached off the
  main actor, and the result is reported by an alert the window applies in one line.
- **D-126 A vanished open page lands the notes pane on its parent, else its book's main page,
  else the reader book's main page** — one place (`AppModel.landNotes`), used by this-window
  trashes and external changes alike. The last step matters once the panes can show different
  books (D-102): a trashed book's pages must never pull the notes back into it.
- **D-127 The toast's undo is registered with the window's `UndoManager` at the action site
  (D-019), in a GlossUI extension: `UndoManager` isn't in swift-corelibs-foundation, so the
  portable models can't hold it.** No redo is offered: restoring isn't something to redo-undo,
  and a fresh trash makes a fresh entry.
- **D-128 A restore says what came back through `TrashModel.lastRestoredMessage`** (portable
  copy: `restored “x” and 2 more`), shown as a small material note at the bottom of the trash
  view; the cascade rule (D-029) means the extras can be containers, so the copy stays vague
  on purpose.

- **D-130 Search is `.searchable` in the toolbar with `.searchScopes`, results replace the detail
  column.** Mail shows search results in the content area and Books closes the search when a
  result is chosen; together that is the least chrome for a window whose content is already a
  list. The scope menu appears on text entry (`searchScopes(activation: .onTextEntry)`), and the
  window adopts the context's default scope when the open document changes (brief 32).
- **D-131 Open Quickly is ⇧⌘O in the File menu, presented as a sheet.** D-071 fixed the key;
  Xcode's Open Quickly lives in File, and a small sheet is the standard SwiftUI way to host one
  field plus a result list. Keyboard: up/down/return via `onKeyPress` (macOS 14), escape is the
  sheet's own cancel; an empty query shows nothing, like Xcode.
- **D-132 Every URL from outside goes through one portable door, `AppModel.open(url:)`.** The
  classifier (`IncomingURLClassifier`: gloss link / registered file / other) and the routing are
  testable on Linux, and pane-independent navigation (brief 15) can switch the one call inside.
  Failures land in one copy helper (`UnopenableLinkCopy`), ready for main's `RouteOutcome.problem`.
- **D-133 GlossUI does not depend on GlossExport.** `GlossAppModel` does (it already owns the
  window models), and its `ExportModel` wraps the `ExportService` the composition root builds —
  the same wiring the cli's root has. Views only see `ExportModel`, so no view constructs a
  service and no new Mac-target dependency is needed beyond GlossAppModel itself.
- **D-134 Print renders the html export in an offscreen WKWebView.** The html exporter was built
  for exactly this ("export as PDF through the system print dialog"), so ⌘P (File › print…,
  replacing the empty print group) exports the open page with its subpages to html, loads it into
  a non-persistent offscreen web view, waits for `didFinish`, and runs `printOperation(with:)` —
  whose print panel carries the pdf menu.
- **D-135 Finder double-clicks are imports, duplicates open the existing copy.** A file URL
  arriving through `onOpenURL` is classified by the registered formats' extensions and goes
  through the one import entry point, `LibraryModel.importFiles`; `lastDuplicates` records what
  was already in the library so the existing copy is still opened.
- **D-136 External urls reach an existing window.** The window group carries id "main" and
  `handlesExternalEvents(matching: ["main"])`, so a `gloss://` link or a Finder double-click
  routes to an open window instead of opening a duplicate (the documented SwiftUI routing pair;
  `WindowGroup.init(id:content:)` is deprecated from macOS 15, so the stub spells the surviving
  `init(id:makeContent:)`). What can't be opened gets a window alert, not a toast — a bad link
  from outside deserves a modal answer.
- **D-137 The dev Info.plist declares the url scheme and the book formats.** `scripts/run-mac.sh`
  writes `CFBundleURLTypes` for `gloss` and `CFBundleDocumentTypes` for the system's epub and pdf
  UTIs (the registered formats live in code; v1 ships epub and pdf).
- **D-138 The quick switcher debounces typing and owns its keyboard selection.** The sheet is
  presentation only; `QuickSwitcherModel` gained the debounced query, the selected row and
  `settle()`, Linux-tested like `SearchModel`.
- **D-139 A search reveal waits for the book like a passage jump.** `ReaderController.reveal`
  queues while the open book isn't showing and lands after `.opened` (the existing
  pendingFocus pattern), so choosing a hit right after opening a book is never dropped.
- **D-142 Paginated EPUBs take trackpad gestures natively and drag the page.** `ReaderWebView`
  overrides `scrollWheel` in paginated flow and forwards each event with its `NSEvent` phase to
  `glossReader.swipe`; momentum is swallowed. A horizontal gesture drives foliate's own touch path
  (`scrollBy` while the fingers move, `snap` with the lift velocity), mouse notches turn one
  page and vertical swipes are ignored (pages slide sideways); the paginator gets `animated` (unless reduce motion). Reason: DOM wheel events carry
  no phase, so the page can't tell a lift from momentum or one swipe from the next — that is why a
  page-per-gesture wheel handler felt wrong. Gesture logic lives in `web/src/bridge/swipe.ts` (tested).
- **D-143 Debounced models sleep through a named function, never a default-argument closure.**
  `AppSettingsModel` and `DeletionModel` defaulted `sleep` to `{ try await Task.sleep(for: $0) }`;
  Swift 6.2.3 miscompiles that closure in a `@MainActor` init's default argument, so cancelling the
  pending save (any second settings change) aborted in `swift_task_dealloc` ("freed pointer was not
  the last allocation", crash reports of 2026-11-13). `taskSleep(_:)` (GlossAppModel) replaces it;
  a test drives quick changes with the real sleep (it reproduced the abort on macOS).
- **D-144 The EPUB reader is one solid theme colour, edge to edge.** The reader page was
  transparent, so wherever foliate's section iframe didn't paint (margins, column gap, the blank
  pages around a section, and the whole frame whenever its `#background` copy came out empty) the
  WKWebView's own white showed; book CSS could also out-rank the theme's `html` background or paint
  `body` per column. Now the glue sets `--gloss-background`/`--gloss-foreground` and `color-scheme`
  on the reader page (`reader.css`, system `Canvas` before the first appearance), the theme's
  `html` colours are `!important`, `body` is transparent, `underPageBackgroundColor` follows live
  theme changes, and the night theme also overrides the book's text/box colours (dark text on a
  dark page is unreadable). The themes stay light, sepia (default) and night; none follows the
  system appearance, so a dark-mode Mac still reads sepia until night is chosen (an "auto" theme
  would be additive).
- **D-145 The Settings window is a grouped form, reading first, with a sample page.** The plain
  macOS `Form` (columns style) printed each slider's label twice (its own and `LabeledContent`'s)
  with the bare number in between, and stacked menus for two- and three-way choices. Now:
  `.formStyle(.grouped)` like System Settings, segmented pickers for theme/layout/columns, sliders
  with a fixed-width value, columns disabled in scrolled flow, a sample paragraph in the theme's
  colours and size, the save problem as a section footer, and the window sized to its content.
  "reading" leads because it is why people open Settings; still no tabs (D-121).
- **D-146 Subpage rows are hit, drawn and highlighted by their first line fragment, at a fixed
  height.** Re-diagnosis of 1d26dd5: (1) when a row is the last paragraph and the text ends with
  its newline, TextKit 2 keeps the empty last line (the extra line fragment) inside the row's own
  layout fragment, so the row, drawn centred on the whole fragment, slid half a line down over the
  new line, and hit-testing by character index / fragment frame mapped clicks there to the row
  (one more Return moves the extra line into its own paragraph, hence "fixes itself"); (2) with
  the caret at the row's end, the link's syntax was revealed (hidden, but full width), so the
  line could wrap and grow; (3) TextKit 2 renders fragments into cached layers, so a block painted
  in `NSTextView.draw(_:)` doesn't reliably show or repaint. Now the row's line has a paragraph
  style with min = max line height 28 pt and clipping (`TextStyle.Block.row`), syntax inside a row
  never reveals (`SyntaxReveal.apply(concealed:)`), the fragment draws in `rowRect` (first line
  fragment's typographic bounds, container width), clicks and hover hit that rect
  (`NotesTextView.rowHit`), and the hover block is a hit-transparent subview placed below the
  text's.
  Follow-ups: every run now carries a font (plain runs fell back to Helvetica 12, so the row's
  body-font title looked bigger than the notes); the row's icon is the symbol configured at the
  body font's size and drawn at its own aspect; the hover block clears on a row click and when
  another page's text is installed.
- **D-147 The sidebar's contents and notes trees are indented rows, not `OutlineGroup`s.** An
  expandable row makes the sidebar's outline view reserve the disclosure triangle's room for every
  row (Mail does this too), so with a book open "library" and "reading" shifted right of where they
  sit on the library, and jumped back on "all". `OutlineRow.rows` flattens a tree with depths
  (GlossAppModel, tested) and the list indents nested rows 14 pt per level; the trees no longer
  collapse per node (Books' contents don't either), only per section.
- **D-148 Import progress is a small ring in the toolbar; the drop target is an accent outline.**
  The floating capsule at the bottom of the grid ("reading…", "storing…") and the "drop to add"
  banner were custom chrome. Safari's downloads and Mail's activity put progress in the toolbar, so
  a small circular `ProgressView` appears there while an import runs (in any detail, since Finder
  and `gloss://` imports can run with a book open): determinate over the counted files
  (`LibraryModel.importCompleted/importTotal`; folders are listed first), spinning before that,
  the per-file status as its tooltip and VoiceOver label, and an announcement at the end
  (`ImportSummary.announcement`). Duplicates and failures keep the existing alert. Per-cover
  progress (Books' downloads) doesn't fit: a book has no cell until it has been stored. A drag
  over the window draws only an accent rounded outline, like Finder and Mail.
- **D-149 (supersedes D-122's live apply) Open books take new reading settings when Settings
  closes.** The user doesn't want the book re-flowing under every slider step. Edits still save
  debounced (nothing is lost on quit), but only `AppSettingsModel.flushSave()`, called from the
  Settings view's `onDisappear`, announces `glossSettingsChanged`, once, and only if the values
  differ from what was last announced or loaded; every window's `AppModel` then applies the
  appearance to its open EPUB and AppRoot's appearance source updates for later opens. The sample
  page inside Settings is the live preview: it reads the model's draft values and shows theme,
  size, spacing, margins (half scale) and columns/flow.
- **D-150 Back/forward is its own toolbar item, a navigation-style `ControlGroup`.** Packed with
  the title into one `HStack` item whose shared background was hidden (macOS 26), the chevrons
  lost the system's grouped capsule and floated apart. Now the pair is a `ToolbarItem(.navigation)`
  holding `ControlGroup { back; forward }.controlGroupStyle(.navigation)` (macOS 12; "a separated
  momentary segmented control" on macOS), and the title is a second `.navigation` item declared
  after it, only its background hidden on macOS 26. macOS 14 keeps the system title, which the
  docs place after navigation items.
- **D-151 The results pane follows the search being open, not the query being non-empty.**
  Clearing the field mid-search dropped the window back to the library. `SearchModel.isPresented`
  is bound to the field (`searchable(text:isPresented:…)`, macOS 14) and `showsResults` is
  `isPresented || hasQuery`: an open, empty search shows "search your books and notes" with the
  scope ("type to search this book"); Escape, the cancel button or losing focus with an empty field
  closes it and the detail column comes back; a standing query keeps its results after focus moves.
- **D-152 On macOS 26 search rests as a magnifying-glass toolbar button; sort sits just before it.**
  `searchToolbarBehavior(.minimize)` is documented for iOS/iPadOS/Catalyst/visionOS 26 only, so the
  Mail-style collapsed search is built from system parts: a toolbar `Button` with `magnifyingglass`
  while the search is closed, and while it is open (`SearchModel.showsResults`) the real
  `searchable` field placed by `DefaultToolbarItem(kind: .search, placement: .primaryAction)`. The
  `searchable` lives on a conditional background view so the window's own view tree never changes
  identity. macOS 14/15 keep the standard field. The library's sort menu and the import ring moved
  from `LibraryFeatures` into the window's toolbar builder so the trailing order is fixed:
  [import ring][sort or layout picker][search].
- **D-153 Every trailing toolbar item is declared by the window, search last; search opens and
  closes with an animation.** The trash view's "empty trash" item moved into `MainWindow`'s toolbar
  (its confirmation flag now lives on `LibraryPresentationModel`), so no detail view contributes a
  trailing item that could land right of search. Opening (the button), closing (the field's
  `isPresented` binding) and choosing a result wrap the change in `withAnimation(.smooth)`, `nil`
  under Reduce Motion. A field "growing out of the icon" can't be specified with public toolbar
  API (the toolbar owns its items' layout and the system search field's width), so the animation
  is SwiftUI's transaction on the item swap plus the system's own; if NSToolbar ignores it, the
  swap cuts.
- **D-154 The notes sheet has one margin, 16 pt, everywhere.** It was the card's 8/12/12/12, the
  editor's 12×10 inset, a hand-tuned 17 for the title and 12/6 for the breadcrumbs. Now
  `NotesEditorMetrics.margin` (GlossEditor; `SheetMetrics.margin` in GlossUI) sets the card's
  padding, the breadcrumbs' and title's insets, and the editor's container inset (margin minus the
  text container's own line fragment padding, read at runtime, so glyphs land exactly on it). The
  scroll view stays full-bleed so the scroller sits at the edge. Beside the notes the card has no
  trailing padding and the drag area overlays the notes' leading margin, so the card-to-text gap
  is one margin too. NSTextView's inset is symmetric, so the gap from title to body is also 16 pt.
- **D-155 The notes page title wraps.** `TextField(axis: .vertical)` with `lineLimit(1...)`. A
  vertical field turns Return into a newline, so the title's binding treats a single typed line
  break as Return (commit, then `NotesEditorActions.focusBody()` puts the caret at the body's
  start) and turns any other line breaks (a paste) into spaces: a title stays one line of text.
- **D-156 Trailing toolbar items use `.automatic` behind a flexible spacer, not `.primaryAction`.**
  D-152/D-153 declared them `.primaryAction`, which Apple documents as the toolbar's *leading*
  edge on macOS, so once search became a plain button it sat with the others right after the
  title. Now every trailing item (import ring, sort / layout picker / empty trash, search) is
  `.automatic` ("in order of leading to trailing") and, on macOS 26, a
  `ToolbarSpacer(.flexible)` declared first pushes the cluster to the right edge, search last.
  macOS 14/15 keep the system-pinned search field at the right with the `.automatic` items before it.
- **D-157 (supersedes D-150's custom title) The window shows the system's own toolbar title.**
  D-150/D-153/D-156 kept `toolbar(removing: .title)` (macOS 15+) and drew the title as a custom
  `.navigation` item. In SwiftUI's macOS toolbar the inline title is what separates the leading
  items from the rest; with it removed, every ordinary item packed in right after the chevrons
  whatever its placement (the 00:42 and 00:46 builds), and only the system search field (pinned by
  AppKit) reached the right edge, which is why the very first build looked half right and
  `ToolbarSpacer(.flexible)` changed nothing. Now `navigationTitle` stays, `toolbar(removing:)` and
  the custom title item are gone, and on macOS 26 `DefaultToolbarItem(kind: .title, placement:
  .navigation)` puts the system title right after back/forward explicitly. The `.automatic`
  trailing items and the flexible spacer (D-156) stay, search last.
- **D-158 No `DefaultToolbarItem(kind: .title)`.** Added in D-157 to pin the system title after
  back/forward; on macOS 26 it rendered as an empty glass pill between the chevrons and the title
  (the title text itself is drawn by `navigationTitle`). The system title follows the navigation
  items on its own, so the item is gone (the `.title` stub stays, verified).
- **D-159 Back leaves the search; Escape does too, from anywhere.** Once the field lost focus
  (a click in the results), only clicking back into it and pressing Escape got out. Now
  `WindowCommands` treats an open search (`SearchModel.showsResults`) as the first step back:
  back (toolbar, ⌘[, Go menu) dismisses it and forward is disabled meanwhile; `.onExitCommand` on
  the window dismisses it on Escape wherever focus is. A standing query still survives focus
  moving away, and choosing a result still closes the search.
- **D-160 The search opens and closes in 0.18 s.** `.smooth` (about 0.5 s) felt slow for a toolbar
  field; `SearchMotion` is `.easeOut(duration: 0.18)`, still nothing under Reduce Motion. The same
  transaction carries the detail column's swap to and from the results, and nothing else delays
  it (the 120 ms debounce is for running the query, not for showing the field).
- **D-161 (supersedes the animation parts of D-153 and D-160) The search has no transition.** The
  user wants the icon, the field and the results to switch instantly: the `withAnimation` wrappers
  and `SearchMotion` are gone, and nothing animates the detail column's swap to the results.
- **D-162 Escape closes the search even with no keyboard focus.** The hard way back from a search
  opened in a book: when the book's detail column is swapped for the results, the reader's web view
  (often first responder) leaves the window, and a click on a blank part of the results makes the
  window itself first responder (the detail's tap-to-unfocus). With no SwiftUI focus,
  `.onExitCommand` (D-159) never fired, so Escape did nothing and only back/⌘[ worked. The results
  pane now carries an invisible button with `.keyboardShortcut(.cancelAction)`, which AppKit finds
  as a key equivalent whatever has focus. Back (toolbar, ⌘[, Go menu) already checks the search
  before the book's history and before "back to the library" (D-159), so the book returns as it
  was: same layout, reader session (kept in `readerHost`) and notes page.
- **D-163 The library's sort menu is one level.** A `Picker` inside a `Menu` renders as a submenu
  on macOS ("sort by" › options); `.pickerStyle(.inline)` (macOS 11) lists the orders directly in
  the menu with a checkmark on the current one, under a small "sort by" header. No other Menu in
  the app nests a picker.
