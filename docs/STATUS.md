# Status

Where gloss stands and what comes next. Read this after `CLAUDE.md` when resuming work; then
`docs/ARCHITECTURE.md`, `docs/DECISIONS.md`, `docs/REVIEWS.md` and `docs/MAC_API_NOTES.md`.

_Last updated: 2026-11-13, at tag `review-3-head` (82 commits)._

## Health

- `scripts/check.sh` green: 320 Swift tests in 64 suites, 72 TypeScript tests, the end-to-end CLI
  smoke test (real binary, SQLite, EPUB, PDF, 10 concurrent writers), no compiler warnings, and
  the compiled web output matches `web/src`.
- Every commit since P-004 builds and passes on its own (`scripts/verify-commits.sh`). Known
  exceptions are listed in `docs/DECISIONS.md` (P-001, P-004).

## Milestones

| # | Milestone | State |
|---|---|---|
| 0–8 | foundation, core, markdown, services, sqlite store, formats, export + notes logic, cli, reader bridge + app model | done, tagged `milestone-0` … `milestone-8` |
| — | reader controller, passage linking both ways, notes editor model, `gloss-reader://` routing + CSP | done (Linux-tested), not yet tagged; part of the Mac groundwork |
| 9 | mac: EPUB from the database (app shell, composition root, scheme handler, WKWebView + foliate) | **next** |
| 10 | mac: TextKit 2 editor over `NotesEditorModel` (styling, format bar, slash menu, subpage rows) | to do |
| 11 | mac: linking UI, markers, hover, split view, history, PDFKit engine | to do |
| 12 | mac: library grid, import, details, search UI, open quickly, trash, export/print, backup, settings, external changes, URL handling | to do |
| 13 | polish, README, MIT LICENSE, handoff pass | to do (no README or LICENSE yet) |

## Reviews

| Review | Range | State |
|---|---|---|
| 1 | `milestone-5..review-1-head` | done, findings fixed (`docs/REVIEWS.md`) |
| 2 | `review-1-head..review-2-head` | done, findings fixed |
| 3 | `review-2-head..review-3-head`: reader routing/CSP, engine boundary, reader controller, linking, notes editor model, and the review 1–2 fixes | **running**; fix its findings before starting milestone 9 |

## Next steps, in order

1. Fix review 3's findings in small commits, add them to `docs/REVIEWS.md`.
2. Milestone 9, in thin `[mac-unverified]` slices, each listed in `docs/MACOS_HANDOFF.md` in the
   same commit:
   - targets `GlossReaderKit`, `GlossReaderEPUB` (Swift sources), `GlossMac` with every source
     wrapped in `#if os(macOS)`; `scripts/run-mac.sh` (referenced by the handoff, not written yet);
   - composition root: `SQLiteLibraryStore` at `LibraryLocation.resolve()`, EPUB + PDF formats,
     a PDFKit cover extractor via `FormatRegistry.adding(coverExtractor:for:)`, `AppModel`, a 1 s
     timer calling `changeMonitor.poll()`;
   - `WKURLSchemeHandler` that only executes `ReaderResourceRouter.route(_:)`: reader files from
     the bundle, books from `BlobStore`, headers from `ReaderResourceRouter.headers`.
     `WKURLSchemeTask` is not `@MainActor`, and calling it after `webView(_:stop:)` raises;
   - `WKWebView` with `WKWebsiteDataStore.nonPersistent()`, handler named `gloss`, events through
     `ReaderEvent.decode` → `EPUBBridgeDriver.translate` → `ReaderController.handle`; commands via
     `callAsyncJavaScript("return await window.glossReader.receive(command)", arguments:
     ["command": <JSON object>], contentWorld: .page)` (macOS 12+ async variant);
     `underPageBackgroundColor` for the background (there is no public `drawsBackground`).
3. Milestones 10–12 as planned in `docs/ARCHITECTURE.md` §7–§10, following the design principles
   in `CLAUDE.md` (system components first, Apple Notes shortcuts, ⇧⌘O open quickly).
4. An independent max-effort review after each finished chunk; fix, then continue.
5. Milestone 13: README, `LICENSE` (MIT), copy review, final handoff pass.
