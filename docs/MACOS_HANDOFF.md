# macOS handoff

Everything in this file was written on Linux and has **never been compiled or run**. It is the
checklist for the first sessions on a Mac. Commits that touched these files carry
`[mac-unverified]` in their subject (`git log --grep mac-unverified`).

## How to build on the Mac

```sh
swift build                 # Linux + Mac targets
swift test                  # Linux-testable suites (run on macOS too)
(cd web && pnpm install --frozen-lockfile && pnpm test)
scripts/run-mac.sh          # builds GlossMac and wraps it in build/gloss.app (dev only)
```

## Verify first (riskiest parts)

1. **EPUB opens from the database in the web view.** _(not written yet)_
   - **Book scripts never run.** Import an EPUB whose chapter has an inline `<script>`, an
     `onload="…"` attribute and an external `<script src>` that each `fetch` a `gloss-reader://app/book/…`
     URL and post a message: nothing may execute. Then disable the glue's sanitizer (`guardScripts` in
     `web/src/glue.ts`) and check again: the page CSP alone must still stop them (WebKit inheriting the
     policy into `blob:` documents is the unverified assumption; docs/READER_BRIDGE.md "Book scripts").
   - **Switching books in place:** open book A, then B from the library, then A again quickly; the reader
     always ends on the last one asked for, and A's position is never saved onto B.
2. **Passage links resolve in both directions** (notes → book and book marker → note). _(not written yet)_
3. **Native markdown editor with links and the floating formatting bar.** _(not written yet)_

## Every Mac slice: Apple-likeness pass

- Compare against Books, Notes and Preview: system components, standard menus and shortcuts, no custom
  chrome, modes or banners (CLAUDE.md "Design principles").
- Light and dark appearance, Increase Contrast, Reduce Motion and Reduce Transparency all look right.
- VoiceOver reads every custom control (format bar, slash menu, link chips, subpage rows, markers).
- Copy is lowercase, short and clear.

## Checklist by file

### `Sources/GlossReaderKit/` (milestone 9)

- `ReadingEngine.swift` — protocols and registry only; should just compile.
- `ReaderPane.swift`
  - The placeholder shows over the engine view for: no book, no engine for the kind (PDFs until
    milestone 11), and a book that failed to open. It must not cover a book that is showing.
  - `.task(id: reader.document?.kind)` creates the session the first time a book of a kind opens;
    switching EPUB → EPUB keeps the same web view (watch for a flash or a reload: there must be none).
  - `ReaderHostView` returns the session's view from `makeNSView`; check it resizes with the window and
    that closing the window releases the web view (no leak in the memory graph).

### `Sources/GlossReaderEPUB/` (milestone 9)

- `ReaderSchemeHandler.swift`
  - Open a large EPUB and switch away mid-load: no "task already stopped" exception (a load finishing
    after `webView(_:stop:)` must find no entry and drop its answer).
  - Check the Web Inspector's network tab: every `gloss-reader://` response carries `Content-Type`,
    `Cache-Control: no-store` and `nosniff`; module scripts load (WebKit refuses modules with a wrong type).
- `EPUBReaderSession.swift`
  - The page loads, the glue posts `ready`, the book opens at the saved position (risk #1).
  - Events arrive as strings (`postMessage(JSON.stringify(…))`); a non-main-frame message is ignored.
  - Clicking a web link in a book opens the browser (via `linkActivated`), never navigates the web view;
    `target=_blank` links open nothing in the app.
  - Kill the web content process (Activity Monitor, "gloss Web Content"): the page reloads and the book
    comes back where it was.
  - `underPageBackgroundColor` matches the theme when scrolling past the edges (sepia by default).
  - In debug builds the page is inspectable in Safari's Develop menu.
- `EPUBReadingEngine.swift` — `ReaderBundle.directory()` finds `reader/` both in `build/gloss.app` and
  when running the bare executable (`swift run GlossMac`).

## APIs I was unsure about

- `ContentUnavailableView(_:systemImage:description:)` is verified with a `LocalizedStringResource`
  title; the code passes string literals.
- `WKWebViewConfiguration()`: Apple's docs JSON has no page for a no-argument initializer (only
  `init(coder:)`), though Apple's own sample code calls it.
- `Bundle(url:)` over SwiftPM's resource bundle copied into `Contents/Resources`, and
  `url(forResource: "reader", withExtension: nil)` finding a directory in it.
- `WKWebView.load(_:)` and `reload()` return `WKNavigation?` without `@discardableResult`, hence `_ =`.
