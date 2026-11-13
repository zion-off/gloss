# macOS handoff

Everything in this file was written on Linux and has **never been run**. It is the checklist for
the first sessions on a Mac. Commits that touched these files carry `[mac-unverified]` in their
subject (`git log --grep mac-unverified`).

Since D-099 the Mac modules **type-check** on Linux against stub frameworks
(`scripts/mac-typecheck.py`). A compile error on the Mac therefore most likely means a stub
disagrees with the real SDK: fix the code, the stub and `docs/MAC_API_NOTES.md` together. Known
modelling choices in the stubs: imported methods returning values are `@discardableResult` (Swift
never warns about unused results of Objective-C methods), and SwiftUI's `task` modifier inherits the
actor context, as its SDK interface says (`@_inheritActorContext`, absent from the docs JSON).

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
2. **Passage links resolve in both directions** (notes → book and book marker → note). Written in
   milestone 11 over the Linux-tested `LinkingCoordinator` and `ReaderController`; details in the
   `GlossReaderPDF`, `ReaderPopovers` and `WindowCommands` sections below.
   - In split view select words in the notes, select a passage in the book, press ⌘K: the words
     become a `gloss://passage/…` link in one undo step, and once the page saves a marker appears
     under the passage. Do it in an EPUB and in a PDF (on page 2 or later).
   - Click the link: the reader goes to the passage and flashes it. Click the marker: the notes page
     opens with the link selected and flashed; a passage linked from two pages lists both first.
   - Rest the pointer on the link: a popover shows the passage's quote, label and book.
   - Delete the link, then ⌘Z: the marker goes and comes back. Remove it with `gloss page write`
     from the terminal: the marker goes within about a second (the change monitor).
   - **Across books (D-102):** with book A's notes open, follow a link to book B (or go back in the
     reader to B): the reader swaps, the notes stay on A, and the sidebar's notes section reads
     "notes · A". Select words in A's notes and a passage in B, press ⌘K: the marker appears in B.
     Click it: A's note opens beside B without the reader moving. Click into the reader and press ⌘[:
     only the reader goes back; click into the notes and press ⌘[: only the notes do.
   - A link to something in the trash or deleted for good says so in an alert instead of doing
     nothing.
3. **Native markdown editor with links and the floating formatting bar.** Written in milestone 10;
   details in the `Sources/GlossEditor/` section below.
   - Type markdown (headings, emphasis, lists, task boxes, quotes, code): it styles as you type and the
     text stays raw markdown (`gloss read --raw` shows exactly what you typed).
   - Select words: the format bar appears above the selection (below it near the top of the pane);
     its buttons and the Format menu's shortcuts each make one undo step.
   - Type `/` on an empty line: the slash menu filters as you type, arrows and Return pick, Escape
     closes. A subpage made there shows as a row that opens the page.

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
- `Sources/GlossUI/MainWindow.swift` (moved from GlossMac in milestone 12; it now takes the
  services, the engines and the once-per-launch `prepare` from the root)
  - Selecting a book opens it; selecting another switches in place; the window title is the book's.
  - Trash the open book with `gloss book trash` while it's showing: the reader blanks to "pick a book".
  - A second window (⌘N) has its own reader and selection.
  - The poll loop stops when its window closes (no polling from closed windows).
- `PDFKitCoverRenderer.swift` — import a PDF; its cover is the first page. Rotated first pages may come
  out sideways (rotation isn't applied); check, and use `PDFPage.rotation` if so.
- `scripts/run-mac.sh` — builds `build/gloss.app` (ad hoc signed) and opens it; `--no-open`, `--release`.

### `Sources/GlossReaderPDF/` (milestone 11)

- `PDFReaderSession.swift` — one object is session, driver and overlay provider (no bridge).
  - Open a PDF from the sidebar: it renders, the position saves, reopening returns to the page.
  - Select text: the selection popover (highlight colours, add to notes) anchors to the first line.
  - Highlights fill in their colours, markers underline; clicking either opens its popover; clicks
    outside them select text normally (the overlay's `hitTest` returns nil there).
  - ⌘K over a book selection + a notes selection links them; the marker appears on the PDF page
    **at once, without scrolling** (review 6: `show(_:)` pushes new marks into the overlays on
    screen; every page gets an overlay, marked or not).
  - The flash outline on a passage jump appears and fades after 1.5 s.
  - A passage jump puts the passage's first line at the top of the view: the destination's point is
    the top of that line, taking PDFDestination's point as the view's top-left corner (PDF's own
    /XYZ model; Apple's docs only say "page space"). If the line lands just above the view, use the
    line's bottom instead.
  - Links inside the PDF open in the browser, never in the reader.
  - `.PDFViewPageChanged` / `.PDFViewSelectionChanged` — the Swift spelling of the two notification
    names is the importer's; the docs JSON only has the ObjC extern. If they don't compile, the fix
    is the spelling on this line.
  - The overlay converts page → PDF view → itself when drawing, and superview/window → PDF view →
    page for clicks (review 6: PDFKit places each overlay over its page, not at the PDF view's
    origin). Verify highlights and markers land on their text **on the second and later pages**,
    at several zoom levels, and that clicks on them hit (and clicks beside them select text).
  - The marker underline sits under the text's baseline side whether or not the overlay is flipped.
  - A search hit with a page jumps to its own occurrence on that page and flashes it; only a hit
    without a locator searches the whole document.
  - The TOC comes from the PDF outline (nested, at most 4 levels and 2000 nodes); entries whose
    destination PDFKit can't resolve hand their children up instead of pointing at page 1.
- `PDFReadingEngine.swift` — registration only; PDFs now open with an engine (the "can't show this
  kind" placeholder should be gone).

### `Sources/GlossReaderKit/ReaderPopovers.swift` + `ReaderPane.swift` (milestone 11)

- One popover at a time over the reader, anchored to the selection/mark (top-left `ReaderRect`
  contract): selecting text offers the five highlight colours and "add to notes"; clicking a
  highlight offers recolouring (current colour checked) and "remove highlight" (⌘Z restores it);
  clicking a marker linked from several notes lists them with the linking line.
- The popover is attached to a transparent overlay at `.rect(.rect(anchorRect))`; check it points at
  the selection at different window sizes and scroll positions, in both engines. CSS px = points is
  assumed for the EPUB engine's anchors (true at the default zoom).
- `UndoManager.setActionName(_:)` (standard, not in the verified notes) names the undo item.
- The session host belongs to the window: switch to notes only (⌥⌘3) and back (⌥⌘1) — the book must
  stay where it was without reloading.

### `Sources/GlossUI/WindowCommands.swift` (milestone 11)

- The Go menu: back/forward (⌘[/⌘]), acting on the notes pane when the editor has focus, else the
  reader. Check that focus routing is right: click into the reader, ⌘[ goes back a book; click into
  the notes, ⌘[ goes back a page.
- "link to passage" (⌘K) and "add to notes" in the Format area after the text formatting items.
  Both apply through the editor's coordinator (one undo step). Enabled state comes from the models:
  ⌘K disabled with the hint as its tooltip ("now select a passage in the book", …).
- Two windows: the commands act on the key window's models (`focusedSceneValue`).
- View menu: "reader and notes" ⌥⌘1, "reader only" ⌥⌘2, "notes only" ⌥⌘3, checkmarked (toggles); the
  toolbar's segmented control mirrors them. The layout persists and applies to every window.
- Toolbar: back/forward on the leading edge (a `ControlGroup`), the layout switch on the trailing
  side. SF Symbols `rectangle.split.2x1`, `book`, `note.text`, `chevron.left/right` — standard names,
  but check they render.

### `Sources/GlossUI/SourceList.swift` + `MainWindow.swift` (milestone 12)

- One source list (D-101), `.sidebar` style: "library" (all, books, pdfs with their formats'
  symbols, trash with a count badge that disappears at zero), then, with a book open, "reading" (the
  book), "contents", "highlights" and "notes" — the last three collapsible, remembered per window
  across relaunches (`@SceneStorage`).
- The detail column follows the selection: a shelf shows the library, the trash shows the trash, the
  book and anything in it show reader and notes. Click "all", then the book again: the reader must
  come back where it was without reloading (the session lives in the window).
- Clicks go through `AppModel.select`, which updates `workspace.sidebar` asynchronously; check the
  highlight doesn't flicker back to the previous row on a click (a page row awaits the page read
  first). Clicking empty space must not deselect.
- A contents entry jumps the reader there; a highlight jumps and flashes it; a page opens it in the
  notes. Each reveals its pane when the layout hides it (try from "notes only" and "reader only").
- Highlights: colour dot, two lines of passage, its location label. Right-click › "remove
  highlight" and the delete key (Edit › Delete via `onDeleteCommand`) both remove it; ⌘Z brings it
  back and the row returns.
- Long tables of contents: check scrolling and that nested entries disclose (`OutlineGroup`) and
  stay disclosed while the reader moves; untitled pages show as "untitled".
- The title bar follows the detail column: the shelf's name, "library", "trash", or the book's title.

### `Sources/GlossUI/LibraryGrid.swift` + `LibraryFeatures.swift` + `LibraryCommands.swift` (milestone 12)

- The library grid: covers in adaptive columns (Books-style), the format's badge bottom-trailing
  on the cover, a thin progress bar only under books that were opened, title and author below.
  Check light/dark, and that the generated fallback (title/author on a tinted cover) never
  changes colour for the same book across relaunches.
- A single click opens the book; the context menu offers open, edit details…, move to trash
  (trash is a no-op until the trash slice is wired at merge — the item should appear but do
  nothing yet).
- The "recently read" shelf shows above the grid on "all" only, and disappears on a filtered
  shelf or when nothing was opened yet.
- The sort menu (trailing toolbar, arrow.up.arrow.down) switches recent/title/author/date added;
  the choice survives relaunch and a **second open window** follows within a second (its menu
  checkmark moves too).
- Empty states: no books at all → "nothing glossed yet" with an import… button; a filtered shelf
  with no books → "no pdfs yet" (the shelf's name).
- File › import… (⇧⌘A) opens an NSOpenPanel as a sheet: multiple files AND folders, filtered to
  epub/pdf. Importing shows the bottom status line ("reading…", "storing…", "added …") and never
  beachballs. Importing a duplicate shows the "already in your library" alert; "open it" opens
  the existing copy.
- Drag files or a folder anywhere onto the window: the library rings with "drop to add to your
  library" and the import runs. **Verify a drop over the reader's web view still reaches the
  window-level drop zone** — WKWebView has no public drag API (MAC_API_NOTES), but if it
  swallows file drags the drop needs a grid-level `onDrop` too.
- Dropping a non-book file (a .png, say) anywhere outside the details sheet is silently ignored
  (the extension filter drops it); check nothing looks broken.
- Import progress while the library isn't the visible detail (a book is open): the status line
  isn't visible then — acceptable, but check the import still completes and the grid updates
  when you go back to it.
- Two windows: import from one; the other's grid follows within a second (its change poll).

### `Sources/GlossEditor/` (milestone 10)

- `NotesEditorTheme.swift` — system fonts and colours only; check light/dark, Increase Contrast
  and Reduce Transparency all look right, and that headings/code/quotes read like Notes'.
- `NotesTextView.swift` — a click toggles a task box and opens a subpage row; verify the click
  target feels right (the box glyph plus half a character either side, not the whole line). Clicks
  map through `characterIndexForInsertion(at:)` in view coordinates (review 6: the old
  `characterIndex(for:)` wanted screen coordinates).
- `NotesEditorCoordinator.swift`
  - Typing is native (input methods, undo, find bar); the buffer must stay the raw markdown.
  - Smart quotes/dashes/text replacement are off — type `"` and `--` and they must stay ASCII.
  - The format bar and slash menu anchor to the selection/caret and follow scrolling
    (bounds-change notifications recompute the anchor); check they stay inside the window.
  - **The format bar sits above the selection when there's room and below it otherwise**, at the
    top and the bottom of a long page, scrolled and not. The anchor flips into SwiftUI's top-left
    space only when the scroll view isn't flipped (review 6 doubted review 5's unconditional flip);
    a bar mirrored to the other end of the pane means `isFlipped` isn't what the conversion
    assumed.
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
- `NotesEditorCoordinator.swift` — the fragment delegate is `nonisolated` and builds the fragment
  there (TextKit's classes aren't main-actor isolated); only the read of the model's rows uses
  `MainActor.assumeIsolated`. It must never be hit from a background layout pass; if it ever crashes
  there, the rows snapshot needs a lock instead. `SubpageRowFragment` is not main-actor isolated
  either (its superclass isn't).
- `NotesHover.swift` + the text view's tracking area — resting the pointer on a passage link shows
  its quote, label and book in a transient popover (120 ms rest, one lookup per link, cancelled on
  move). Check: the popover anchors to the link's line, closes on click/scroll/leave, and nothing
  shows over web or page links. Leaving a link within the 120 ms rest must not open the popover
  over plain text afterwards (review 6: the pending lookup is cancelled on every close). The
  `NSTrackingArea(rect: .zero, … .inVisibleRect …)` pattern is documented (the rect is ignored) but
  needs a run.
- `Sources/GlossUI/MainWindow.swift` — the editor pane: page loads, the unsaved-changes alert,
  breadcrumbs, and the reveal (a marker click selects the link line and scrolls to it). The split
  layout switches with the workspace setting (reader and notes in an `HSplitView` since milestone 11).

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
- `NSColor.separatorColor` (verified, 10.14+) in the slash menu border, via `Color(nsColor:)`
  (verified, 12.0+): SwiftUI's `Color` has no `separatorColor`.
- Whether a paragraph's `elementRange` includes its line terminator (the row matcher handles
  either; verify rows actually draw on a real page).
- `textView.undoManager` being non-nil with `allowsUndo = true` when `install()` clears it.
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
- `NSImage(systemSymbolName:accessibilityDescription:)` (verified, 11.0+) and
  `NSAttributedString.draw(in:)` / `size()` (verified; `size()` is a method) inside an
  `NSTextLayoutFragment.draw(at:in:)` — drawing there needs a run.
- `NSTextContentStorage.documentRange` reached through `textContentManager` (documented on
  `NSTextElementProvider`, which it implements) and `NSTextParagraph.elementRange` mapping to
  UTF-16 offsets via `offset(from:to:)` — each verified, the composition needs a run.
- `PDFDocument` and `PDFPage.thumbnail(of:for:)` off the main thread (imports run there).
- `NSOpenPanel()`/`NSSavePanel()` (no initializer docs page; Apple sample code calls them) and
  `beginSheetModal(for:)` with the key window grabbed from `NSApplication.shared.keyWindow` out
  of SwiftUI — the sheet attaches to the SwiftUI window only if it is the key window when the
  command runs; if the import panel ever appears detached, that is why.
- `NSOpenPanel` with both `allowedContentTypes` set and `canChooseDirectories = true`: the type
  filter should apply to files while folders stay selectable — the docs don't spell the
  combination out; if folders grey out, drop `allowedContentTypes` and filter in code.
- `UTType(filenameExtension:)` returns nil for extensions no app on the Mac claims, so a
  registered format with such an extension would be unpickable in the import panel (epub and
  pdf are both system-claimed; only a future exotic format could hit this).
- `NSItemProvider.loadObject(ofClass: URL.self)` for Finder drags (the bridged generic overload)
  and one `onDrop` at window level receiving drops over the WKWebView reader — both need a run.
- The details sheet's image panel presented as a sheet on the sheet (`beginSheetModal` for the
  cover panel while the details sheet is the key window): nested sheets are standard AppKit,
  but the stacking needs a look.
