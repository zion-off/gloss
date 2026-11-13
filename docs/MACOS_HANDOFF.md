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

_(filled in as Mac code lands)_

## APIs I was unsure about

_(filled in as Mac code lands)_
