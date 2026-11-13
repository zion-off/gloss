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

1. **EPUB opens from the database in the web view.** Written in milestone 9: import a book with
   `gloss import`, run `scripts/run-mac.sh`, pick it in the sidebar.
   - **Book scripts never run.** Import an EPUB whose chapters cover every vector: an inline
     `<script>` and an `onload="…"` attribute, an external `<script src>`, a `<template>` holding
     both, an SVG with a script and a `<set attributeName="onbegin">`, and — the vectors review 4
     added — one chapter whose media type is `application/xml` (and an `<iframe src>` pointing at
     another `application/xml` item) containing an XHTML-namespace script; each `fetch`es a
     `gloss-reader://app/book/…` URL and posts a message: nothing may execute. Then disable the
     glue's sanitizer (`guardScripts` in `web/src/glue.ts`) and check again: the page CSP alone must
     still stop them (WebKit inheriting the policy into `blob:` documents is the unverified
     assumption; docs/READER_BRIDGE.md "Book scripts").
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

### `Sources/GlossMac/` (milestone 9)

- `GlossApp.swift` — on Linux this target is a stub that prints a line (D-084); on the Mac `@main`
  must pick the SwiftUI branch. A library that can't open shows the failure instead of a window.
- `AppRoot.swift`
  - The library opens at `~/Library/Application Support/gloss/library.sqlite` (or `GLOSS_LIBRARY`),
    the same file the cli uses: import with the cli while the app runs and the book appears within a
    second or so.
  - Reading settings saved in the store give the theme of the first book opened.
  - Maintenance runs once at launch, off the main actor.
- `MainWindow.swift`
  - Selecting a book opens it; selecting another switches in place; the window title is the book's.
  - Trash the open book with `gloss book trash` while it's showing: the reader blanks to "pick a book".
  - A second window (⌘N) has its own reader and selection.
  - The poll loop stops when its window closes (no polling from closed windows).
- `PDFKitCoverRenderer.swift` — import a PDF; its cover is the first page. Rotated first pages may come
  out sideways (rotation isn't applied); check, and use `PDFPage.rotation` if so.
- `scripts/run-mac.sh` — builds `build/gloss.app` (ad hoc signed) and opens it; `--no-open`, `--release`.

### `Sources/GlossEditor/` (milestone 10)

- `NotesEditorTheme.swift` — system fonts and colours only; check light/dark, Increase Contrast
  and Reduce Transparency all look right, and that headings/code/quotes read like Notes'.
- `NotesTextView.swift` — a click toggles a task box and opens a subpage row; verify the click
  target feels right (the box glyph, not the whole line).
- `NotesEditorCoordinator.swift`
  - Typing is native (input methods, undo, find bar); the buffer must stay the raw markdown.
  - Smart quotes/dashes/text replacement are off — type `"` and `--` and they must stay ASCII.
  - The format bar and slash menu anchor to the selection/caret and follow scrolling
    (bounds-change notifications recompute the anchor); check they stay inside the window.
  - Model edits (format bar clicks, Format menu items, slash menu clicks and keys, Return/Tab in
    lists) all go through `NotesEditorCoordinator.apply` and land as ONE undo step each; ⌘Z undoes
    them one at a time and the styling follows.
  - `isRichText = false`: paste rich text from Safari and only the plain text arrives. **Check the
    storage attributes still draw** (heading sizes, dimmed syntax) with rich text off — code
    editors rely on this, but it's unverified here; if they don't, set it back to `true` and
    restrict pasteboard types instead.
  - A marker click in the book selects the link in the notes, scrolls to it and flashes it
    (`showFindIndicator`) — only once the right page is installed (`NotesReveal.pageID`).
  - A failed save shows "couldn't save — your words are still here" at the bottom; switching
    pages then offers keep/discard (Escape = keep editing; never silent loss).
  - Closing a window flushes the editor's pending save and the reader's position (`onDisappear`);
    check with `gloss page read` after closing mid-typing that the last words made it.
  - `.link` attributes make gloss and web links clickable with the pointing hand cursor; gloss
    links route inside the app, web links open the browser.
- `NotesEditorView.swift` — the overlays are SwiftUI over the scroll view, clamped to the pane's
  width (`GeometryReader`); check both stay inside the pane near either edge and at the top.
- `NotesEditorActions.swift`
  - The Format menu replaces the system's text formatting group (Font, Text submenus): its items
    carry Notes' shortcuts (⌘B, ⌘I, ⇧⌘H, ⇧⌘7, ⌘', ⇧⌘M, ⇧⌘K) and are enabled only while the notes
    text view has focus (`becomeFirstResponder`/`resignFirstResponder` overrides).
  - With focus in the reader, ⌘B does nothing (the item is disabled) and never bolds the book.
  - Two windows: the menu acts on the key window's editor (`focusedSceneValue`).
- `SubpageRowFragment.swift` — subpage block lines draw as rows (icon + live title + chevron,
  trashed ones dimmed and struck through) instead of raw markdown. Check: the row's height and
  icon match a Notes-like list, clicking anywhere on the line opens the page, arrow keys still
  step through the hidden line, and a rename from another window refreshes the title
  (`invalidateRows` on the next sync).
- `NotesEditorCoordinator.swift` — the fragment delegate is `nonisolated` with
  `MainActor.assumeIsolated` (TextKit lays out on the main thread); it must never be hit from a
  background layout pass. If it ever crashes there, the rows snapshot needs a lock instead.
- `Sources/GlossMac/MainWindow.swift` — the editor pane: page loads, the unsaved-changes alert,
  breadcrumbs, and the reveal (a marker click selects the link line and scrolls to it). The split
  layout switches with the workspace setting; the real split view is milestone 11.

## APIs I was unsure about

- `ContentUnavailableView(_:systemImage:description:)` is verified with a `LocalizedStringResource`
  title; the code passes string literals.
- `WKWebViewConfiguration()`: Apple's docs JSON has no page for a no-argument initializer (only
  `init(coder:)`), though Apple's own sample code calls it.
- `Bundle(url:)` over SwiftPM's resource bundle copied into `Contents/Resources`, and
  `url(forResource: "reader", withExtension: nil)` finding a directory in it.
- `WKWebView.load(_:)` and `reload()` return `WKNavigation?` without `@discardableResult`, hence `_ =`.
- `.navigationTitle(_:)` with a `String` (only the `LocalizedStringResource` overload page could be
  checked).
- `NSTextView(usingTextLayoutManager: true)` minimum macOS version (docs omit it; TextKit 2 siblings
  are 12.0+ — the target is macOS 14, so only the gap matters for the record).
- `NSView.boundsDidChangeNotification` on the scroll view's clip view (standard AppKit, not in the
  verified notes) and `postsBoundsChangedNotifications` defaulting to true.
- `NSColor.separatorColor` in the slash menu border (standard, not in the verified notes).
- `NSResponder.becomeFirstResponder()`/`resignFirstResponder()` overrides returning `Bool`,
  `KeyEquivalent(Character)`, `@FocusedValue` in a `Commands` type, `@ObservationIgnored weak var`
  in an `@Observable` class, and `@Entry public var` on `FocusedValues` (each standard; none in the
  verified notes beyond `@Entry`/`focusedSceneValue` themselves).
- Storage attributes drawing in a plain-text (`isRichText = false`) TextKit 2 view.
- `firstRect(forCharacterRange:actualRange:)` returning screen coordinates and the screen → window →
  scroll-view conversion chain (`convertFromScreen` then `convert(_:from: nil)`), verified as declared;
  the composed result needs a run.
- `shouldChangeText(in:replacementString:)` + `replaceCharacters(in:with:)` + `didChangeText()` as the
  one-undo-step recipe for programmatic edits (each part verified; the composition needs a run).
- `NSImage(systemSymbolName:accessibilityDescription:)` for the row icon and `NSAttributedString.draw(in:)`
  inside an `NSTextLayoutFragment.draw(at:in:)` (both standard; neither in the verified notes).
- `NSTextContentStorage.documentRange` reached through `textContentManager` (documented on
  `NSTextElementProvider`, which it implements) and `NSTextParagraph.elementRange` mapping to
  UTF-16 offsets via `offset(from:to:)` — each verified, the composition needs a run.
- `PDFDocument` and `PDFPage.thumbnail(of:for:)` off the main thread (imports run there).
